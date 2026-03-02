import SwiftUI

@main
struct SSHMountApp: App {
    @StateObject private var mountManager = MountManager()

    var body: some Scene {
        MenuBarExtra {
            MountListView(manager: mountManager)
        } label: {
            MenuBarIcon(count: mountManager.mounts.count, status: mountManager.aggregateStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let count: Int
    let status: AggregateConnectionStatus

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: status.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(status.color)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(status.color, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
    }
}
