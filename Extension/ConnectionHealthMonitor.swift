import Foundation
import CLibSSH2

/// Connection health monitor for the FSKit extension.
///
/// Simple design: ping SSH every 1s via SFTP stat. If it fails, reconnect
/// with exponential backoff (2, 4, 8, 16s cap). Never gives up.
final class ConnectionHealthMonitor: @unchecked Sendable {

    // MARK: - State Machine

    enum State: Sendable, CustomStringConvertible {
        case connected
        case reconnecting

        var description: String {
            switch self {
            case .connected:    "connected"
            case .reconnecting: "reconnecting"
            }
        }
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
            Log.sftp.notice("ConnectionHealth: \(old.description, privacy: .public) → \(newValue.description, privacy: .public)")
            onStateChanged?(newValue)
            notify_post(newValue == .connected
                ? "com.sshmount.state.connected"
                : "com.sshmount.state.reconnecting")
        }
    }

    /// Called on state transitions. Set by SSHMountVolume to flush caches on reconnect.
    var onStateChanged: ((State) -> Void)?

    /// Called when reconnection should be attempted. Set by SSHMountVolume.
    var onReconnectNeeded: (() -> Bool)?

    /// Called to probe SSH connection health. Returns false if connection is dead.
    var onSendKeepalive: (() -> Bool)?

    private let queue = DispatchQueue(label: "com.sshmount.health-monitor")
    private var keepaliveTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var backoffSeconds: Double = 2
    private static let maxBackoff: Double = 16

    // MARK: - Lifecycle

    func start() {
        running = true
        backoffSeconds = 2
        state = .connected
        startKeepaliveTimer()
    }

    func stop() {
        running = false
        stopKeepaliveTimer()
        stopReconnectTimer()
        stateCondition.lock()
        stateCondition.broadcast()
        stateCondition.unlock()
    }

    // MARK: - Reconnect Trigger

    func triggerReconnect() {
        guard state == .connected else { return }
        state = .reconnecting
        stopKeepaliveTimer()
        scheduleReconnect()
    }

    // MARK: - Wait for Connected

    /// Block the calling thread until state becomes `.connected` or timeout expires.
    func waitForConnected(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        stateCondition.lock()
        defer { stateCondition.unlock() }

        while _state != .connected && running {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            stateCondition.wait(until: deadline)
        }

        return _state == .connected
    }

    // MARK: - Keepalive Timer (1s)

    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connected,
                  let sendKeepalive = self.onSendKeepalive else { return }
            if !sendKeepalive() {
                self.triggerReconnect()
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Exponential Backoff Reconnect

    private func scheduleReconnect() {
        guard running else { return }
        let delay = backoffSeconds
        Log.sftp.notice("ConnectionHealth: next reconnect in \(delay, privacy: .public)s")
        notify_post("com.sshmount.reconnect.delay.\(Int(delay))")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.performReconnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func performReconnect() {
        guard running, let reconnect = onReconnectNeeded else { return }

        if reconnect() {
            state = .connected
            backoffSeconds = 2
            startKeepaliveTimer()
        } else {
            backoffSeconds = min(backoffSeconds * 2, Self.maxBackoff)
            scheduleReconnect()
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }
}
