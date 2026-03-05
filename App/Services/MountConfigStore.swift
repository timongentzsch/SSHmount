import Foundation
import Observation

/// Persistence layer for saved mount configurations.
@Observable
@MainActor
final class MountConfigStore {
    var savedConfigs: [MountConfig] = []

    @ObservationIgnored private let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SSHMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mounts.json")
    }()

    init() {
        loadConfigs()
    }

    func saveConfig(_ config: MountConfig) {
        if let idx = savedConfigs.firstIndex(where: { $0.id == config.id }) {
            savedConfigs[idx] = config
        } else {
            savedConfigs.append(config)
        }
        persistConfigs()
    }

    func deleteConfig(_ config: MountConfig) {
        savedConfigs.removeAll { $0.id == config.id }
        persistConfigs()
    }

    private func loadConfigs() {
        guard let data = try? Data(contentsOf: configURL) else {
            Log.app.notice("No saved mount configs found")
            return
        }
        guard let configs = try? JSONDecoder().decode([MountConfig].self, from: data) else {
            Log.app.error("Failed to decode saved mount configs, resetting file")
            savedConfigs = []
            do {
                try Data("[]".utf8).write(to: configURL, options: .atomic)
            } catch {
                Log.app.error("Failed to reset invalid mount config file: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        savedConfigs = configs
    }

    private func persistConfigs() {
        guard let data = try? JSONEncoder().encode(savedConfigs) else {
            Log.app.error("Failed to encode mount configs")
            return
        }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save mount configs: \(error.localizedDescription, privacy: .public)")
        }
    }
}
