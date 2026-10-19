import Foundation

class MarkerStore {
    static let shared = MarkerStore()
    private let key = "savedMarkers"

    private var store: [String: [Marker]] = [:]

    init() {
        load()
    }

    func markers(for url: URL) -> [Marker] {
        store[url.path] ?? []
    }

    /// Everything on file, keyed by path — the unit a history snapshot records,
    /// because 清空所有标记 empties the whole store, not just the loaded tracks.
    var allMarkers: [String: [Marker]] { store }

    func restoreAll(_ snapshot: [String: [Marker]]) {
        store = snapshot
        save()
    }

    func setMarkers(_ markers: [Marker], for url: URL) {
        store[url.path] = markers
        save()
    }

    func addMarker(at position: TimeInterval, for url: URL, kind: MarkerKind = .global) {
        var markers = self.markers(for: url)
        markers.append(Marker(position: position, kind: kind))
        markers.sort { $0.position < $1.position }
        store[url.path] = markers
        save()
    }

    func removeMarker(_ marker: Marker, for url: URL) {
        var markers = self.markers(for: url)
        markers.removeAll { $0.id == marker.id }
        store[url.path] = markers
        save()
    }

    func removeMarker(id: UUID, for url: URL) {
        var markers = self.markers(for: url)
        markers.removeAll { $0.id == id }
        store[url.path] = markers
        save()
    }

    func clearAll() {
        store.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        var dict: [String: [[String: Any]]] = [:]
        for (path, markers) in store {
            dict[path] = markers.map { m in
                ["id": m.id.uuidString, "position": m.position, "kind": m.kind.rawValue]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }

        for (path, value) in dict {
            if let arr = value as? [[String: Any]] {
                let markers = arr.compactMap { item -> Marker? in
                    guard let idStr = item["id"] as? String,
                          let _ = UUID(uuidString: idStr),
                          let pos = item["position"] as? Double else { return nil }
                    let kind = (item["kind"] as? String).flatMap(MarkerKind.init(rawValue:)) ?? .global
                    return Marker(position: pos, kind: kind)
                }
                store[path] = markers
            }
        }
    }
}
