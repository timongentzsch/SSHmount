import AppKit

/// Open Terminal.app with a new window cd'd to the given directory.
func openTerminal(at path: String) {
    let script = """
        on run argv
            set targetPath to item 1 of argv
            tell application "Terminal"
                do script "cd " & quoted form of targetPath & "; clear"
                activate
            end tell
        end run
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script, path]
    try? process.run()
}

/// Open a single Finder window for the given path.
func openInFinder(path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}

/// Open ~/.ssh/config in the default editor, creating it if needed.
func openSSHConfig() {
    let configPath = PathUtilities.realHomeDirectory + "/.ssh/config"
    let configDirectory = (configPath as NSString).deletingLastPathComponent
    let fileManager = FileManager.default
    let workspace = NSWorkspace.shared
    let fileURL = URL(fileURLWithPath: configPath)

    try? fileManager.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: configPath) {
        try? "".write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    let preferredBundleIDs = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    for bundleID in preferredBundleIDs {
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            workspace.open(
                [fileURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { _, _ in }
            )
            return
        }
    }

    workspace.open(fileURL)
}
