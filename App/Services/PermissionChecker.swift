import Foundation
import Observation

/// Checks required permissions and setup status.
@Observable
@MainActor
final class PermissionChecker {
    var status = PermissionStatus()

    func refresh() async {
        let installed = FileManager.default.fileExists(atPath: "/Applications/SSHMount.app")
        let extensionBundlePath = "/Applications/SSHMount.app/Contents/Extensions/SSHMountFS.appex"
        let extensionBundleExists = FileManager.default.fileExists(atPath: extensionBundlePath)

        var registered = false
        var enabled = false
        if let result = try? await ExtensionBridge.shared.run(
            "/usr/bin/pluginkit", arguments: ["-m", "-i", "com.sshmount.app.fs"]
        ) {
            let pluginID = "com.sshmount.app.fs"
            let mergedOutput = result.stdout + "\n" + result.stderr
            let lines = mergedOutput
                .split(separator: "\n")
                .map { String($0) }

            registered = result.exitCode == 0 && lines.contains { $0.contains(pluginID) }
            enabled = lines.contains { line in
                line.contains(pluginID) && line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            }

            if mergedOutput.contains("Connection invalid") {
                Log.app.notice("pluginkit connection invalid while checking extension status")
            }
        } else if extensionBundleExists {
            registered = true
            enabled = true
            Log.app.notice("Falling back to bundle-based extension status check")
        }

        let home = PathUtilities.realHomeDirectory
        let keyNames = ["id_ed25519", "id_rsa", "id_ecdsa"]
        let hasKeys = keyNames.contains { FileManager.default.fileExists(atPath: "\(home)/.ssh/\($0)") }

        status = PermissionStatus(
            appInstalled: installed,
            extensionRegistered: registered,
            extensionEnabled: enabled,
            sshKeysFound: hasKeys
        )
    }
}
