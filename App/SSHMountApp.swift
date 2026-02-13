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
    
    private var iconName: String {
        status.iconName
    }
    
    private var iconColor: Color {
        switch status {
        case .noMounts: return .secondary
        case .allConnected: return .green
        case .degraded: return .orange
        case .hasErrors: return .red
        case .mixed: return .blue
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
            
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(iconColor, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
    }
}
