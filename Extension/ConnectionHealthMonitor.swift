import Foundation
import CLibSSH2

/// Load-aware connection health monitor for the FSKit extension.
///
/// State transitions:
/// - connected -> suspect: probe failures while transport may still be healthy.
/// - suspect -> reconnecting: sustained idle failures.
/// - reconnecting -> connected: reconnect callback succeeds.
final class ConnectionHealthMonitor: @unchecked Sendable {

    // MARK: - State Machine

    enum State: Sendable, CustomStringConvertible {
        case connected
        case suspect
        case reconnecting

        var description: String {
            switch self {
            case .connected: "connected"
            case .suspect: "suspect"
            case .reconnecting: "reconnecting"
            }
        }
    }

    enum ReconnectReason: String, Sendable {
        case probeTimeout = "probe_timeout"
        case transportError = "transport_error"
        case workerExhausted = "worker_exhausted"
        case manualTrigger = "manual_trigger"
    }

    // MARK: - Properties

    private var _state: State = .reconnecting
    private let stateCondition = NSCondition()
    private var running = false

    private(set) var state: State {
        get {
            stateCondition.lock()
            defer { stateCondition.unlock() }
            return _state
        }
        set {
            stateCondition.lock()
            let old = _state
            guard old != newValue else {
                stateCondition.unlock()
                return
            }
            _state = newValue
            stateCondition.broadcast()
            stateCondition.unlock()

            Log.sftp.notice("ConnectionHealth: \(old.description, privacy: .public) -> \(newValue.description, privacy: .public)")
            onStateChanged?(newValue)

            if newValue == .connected {
                notify_post("com.sshmount.state.connected")
            } else if newValue == .reconnecting {
                notify_post("com.sshmount.state.reconnecting")
            }
        }
    }

    var onStateChanged: ((State) -> Void)?
    var onReconnectNeeded: ((ReconnectReason) -> Bool)?
    var onSendSSHKeepalive: ((Int32) -> Bool)?
    var onSendSFTPProbe: ((Int32) -> Bool)?

    private let queue = DispatchQueue(label: "com.sshmount.health-monitor", qos: .utility)
    private var keepaliveTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var snapshotTimer: DispatchSourceTimer?

    private var backoffSeconds: Double = 2
    private var consecutiveFailures = 0
    private var inflightOperations = 0
    private var lastSuccessfulIOAt: Date?
    private var probeRttEwmaMs: Double?
    private var queueWaitEwmaMs: Double?
    private var lastReconnectReason: ReconnectReason?

    private let healthIntervalSeconds: TimeInterval
    private let healthTimeoutSeconds: TimeInterval
    private let requiredConsecutiveFailures: Int
    private let busyThreshold: Int
    private let graceSeconds: TimeInterval
    private static let maxBackoff: Double = 16

    // MARK: - Lifecycle

    init(
        healthIntervalSeconds: TimeInterval = 5,
        healthTimeoutSeconds: TimeInterval = 10,
        requiredConsecutiveFailures: Int = 5,
        busyThreshold: Int = 32,
        graceSeconds: TimeInterval = 20
    ) {
        self.healthIntervalSeconds = max(1, healthIntervalSeconds)
        self.healthTimeoutSeconds = max(1, healthTimeoutSeconds)
        self.requiredConsecutiveFailures = max(1, requiredConsecutiveFailures)
        self.busyThreshold = max(1, busyThreshold)
        self.graceSeconds = max(0, graceSeconds)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.backoffSeconds = 0.5
            self.consecutiveFailures = 0
            self.inflightOperations = 0
            self.lastSuccessfulIOAt = Date()
            self.state = .connected
            self.startKeepaliveTimer()
            self.startSnapshotTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.stopKeepaliveTimer()
            self.stopReconnectTimer()
            self.stopSnapshotTimer()
            self.stateCondition.lock()
            self.stateCondition.broadcast()
            self.stateCondition.unlock()
        }
    }

    // MARK: - Operation Tracking

    func recordOperationStart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.inflightOperations += 1
        }
    }

    func recordOperationResult(success: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inflightOperations = max(0, self.inflightOperations - 1)
            if success {
                self.lastSuccessfulIOAt = Date()
                self.consecutiveFailures = 0
                if self.state == .suspect {
                    self.state = .connected
                }
            }
        }
    }

    func recordQueueWait(milliseconds: Double, saturated: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let alpha = 0.2
            if let current = self.queueWaitEwmaMs {
                self.queueWaitEwmaMs = current * (1 - alpha) + milliseconds * alpha
            } else {
                self.queueWaitEwmaMs = milliseconds
            }
            if saturated {
                Log.sftp.notice("ConnectionHealth: queue saturation at \(milliseconds, privacy: .public)ms wait")
            }
        }
    }

    // MARK: - Reconnect Trigger

    func triggerReconnect(reason: ReconnectReason = .manualTrigger) {
        queue.async { [weak self] in
            guard let self, self.running, self.state != .reconnecting else { return }
            self.lastReconnectReason = reason
            notify_post("com.sshmount.reconnect.reason.\(reason.rawValue)")
            self.state = .reconnecting
            self.stopKeepaliveTimer()
            self.scheduleReconnect(reason: reason)
        }
    }

    // MARK: - Wait for Connected

    func waitForConnected(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        stateCondition.lock()
        defer { stateCondition.unlock() }

        while _state != .connected && running {
            if deadline.timeIntervalSinceNow <= 0 { return false }
            stateCondition.wait(until: deadline)
        }

        return _state == .connected
    }

    // MARK: - Keepalive

    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + healthIntervalSeconds, repeating: healthIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.evaluateKeepalive()
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func evaluateKeepalive() {
        guard running, state != .reconnecting else { return }

        let probeTimeoutMs: Int32 = 3_000

        // Send SSH keepalive to prevent server-side idle disconnect.
        // Note: this is fire-and-forget (writes to kernel TCP buffer) and
        // does NOT reliably detect a dead network path.
        if let sendKeepalive = onSendSSHKeepalive {
            _ = sendKeepalive(probeTimeoutMs)
        }

        // SFTP probe is the definitive health check — it requires a
        // round-trip response from the server within the timeout.
        if let sendSFTPProbe = self.onSendSFTPProbe {
            let start = Date()
            let sftpProbeOK = sendSFTPProbe(probeTimeoutMs)
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            updateProbeRTT(elapsedMs)

            if sftpProbeOK {
                self.consecutiveFailures = 0
                self.state = .connected
                return
            }
        } else {
            // No SFTP probe available — nothing reliable to check.
            return
        }

        if self.state == .connected {
            self.state = .suspect
        }

        if self.shouldSuppressEscalation() {
            Log.sftp.notice("ConnectionHealth: probe failure suppressed (inflight \(self.inflightOperations, privacy: .public), grace \(self.graceSeconds, privacy: .public)s)")
            return
        }

        self.consecutiveFailures += 1
        Log.sftp.notice("ConnectionHealth: hard probe failure \(self.consecutiveFailures, privacy: .public)/\(self.requiredConsecutiveFailures, privacy: .public)")

        if self.consecutiveFailures >= self.requiredConsecutiveFailures {
            self.triggerReconnect(reason: .probeTimeout)
        }
    }

    private func shouldSuppressEscalation() -> Bool {
        // Only suppress when operations are actually in-flight — load can cause
        // transient probe timeouts.  An idle connection with a failed probe is
        // a genuine signal, not noise.
        guard inflightOperations > 0 else { return false }

        if inflightOperations >= busyThreshold {
            return true
        }
        if let lastSuccessfulIOAt, Date().timeIntervalSince(lastSuccessfulIOAt) <= graceSeconds {
            return true
        }
        return false
    }

    private func updateProbeRTT(_ elapsedMs: Double) {
        let alpha = 0.2
        if let current = probeRttEwmaMs {
            probeRttEwmaMs = current * (1 - alpha) + elapsedMs * alpha
        } else {
            probeRttEwmaMs = elapsedMs
        }
    }

    // MARK: - Reconnect Backoff

    private func scheduleReconnect(reason: ReconnectReason) {
        guard running else { return }
        let jitter = Double.random(in: 0...(backoffSeconds * 0.2))
        let delay = min(Self.maxBackoff, backoffSeconds + jitter)
        Log.sftp.notice("ConnectionHealth: next reconnect in \(delay, privacy: .public)s (\(reason.rawValue, privacy: .public))")
        notify_post("com.sshmount.reconnect.delay.\(Int(backoffSeconds))")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.performReconnect(reason: reason)
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func performReconnect(reason: ReconnectReason) {
        guard running, let reconnect = onReconnectNeeded else { return }
        if reconnect(reason) {
            state = .connected
            backoffSeconds = 0.5
            consecutiveFailures = 0
            startKeepaliveTimer()
        } else {
            backoffSeconds = min(backoffSeconds * 2, Self.maxBackoff)
            scheduleReconnect(reason: reason)
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Observability

    private func startSnapshotTimer() {
        stopSnapshotTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.emitSnapshot()
        }
        timer.resume()
        snapshotTimer = timer
    }

    private func stopSnapshotTimer() {
        snapshotTimer?.cancel()
        snapshotTimer = nil
    }

    private func emitSnapshot() {
        let ioAge: String
        if let lastSuccessfulIOAt {
            ioAge = String(format: "%.1f", Date().timeIntervalSince(lastSuccessfulIOAt))
        } else {
            ioAge = "n/a"
        }
        let rtt = self.probeRttEwmaMs.map { String(format: "%.1f", $0) } ?? "n/a"
        let queueWait = self.queueWaitEwmaMs.map { String(format: "%.1f", $0) } ?? "n/a"
        let reason = self.lastReconnectReason?.rawValue ?? "none"
        Log.sftp.notice(
            "HealthSnapshot state=\(self.state.description, privacy: .public) inflight=\(self.inflightOperations, privacy: .public) ioAge=\(ioAge, privacy: .public)s probeRTT=\(rtt, privacy: .public)ms queueEWMA=\(queueWait, privacy: .public)ms reason=\(reason, privacy: .public)"
        )
    }
}
