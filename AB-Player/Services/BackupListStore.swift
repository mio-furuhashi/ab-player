import Foundation

/// Only the 备用列表 survives across launches; the main playlist stays
/// session-only by design. Restored rows are never existence-checked here —
/// a missing file is only detected when it is assigned to the A/B track.
final class BackupListStore {
    static let shared = BackupListStore()
    private let key = "savedBackupList"

    func save(_ tracks: [Track]) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func load() -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        for i in tracks.indices { tracks[i].missing = false }
        return tracks
    }
}
