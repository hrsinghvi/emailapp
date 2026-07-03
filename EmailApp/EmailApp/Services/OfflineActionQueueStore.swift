import Foundation

/// The whole queue lives in one file (not one-per-action like `DraftStore`)
/// since order matters and the queue is always loaded/replayed as a unit.
enum OfflineActionQueueStore {
    private static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EmailApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("offline_queue.json")
    }()

    static func load() -> [QueuedActionEnvelope] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([QueuedActionEnvelope].self, from: data)) ?? []
    }

    static func save(_ queue: [QueuedActionEnvelope]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
