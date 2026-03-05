import SwiftUI

@main
struct SSHMountApp: App {
    @State private var mountManager = MountManager()

    var body: some Scene {
        MenuBarExtra {
            MountListView(manager: mountManager)
        } label: {
            MenuBarIcon(count: mountManager.mounts.count, status: mountManager.aggregateStatus)
        }
        .menuBarExtraStyle(.window)
    }
}
