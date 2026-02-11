import SwiftUI

@main
struct SSHMountApp: App {
    @StateObject private var mountManager = MountManager()

    var body: some Scene {
        MenuBarExtra {
            MountListView(manager: mountManager)
        } label: {
            Image(systemName: mountManager.aggregateStatus.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
