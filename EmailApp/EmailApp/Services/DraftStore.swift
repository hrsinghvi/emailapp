import Foundation

/// File-based draft persistence — one JSON file per draft under Application
/// Support. Simple enough that a draft can never half-write: each save
/// replaces the whole file atomically.
enum DraftStore {
    private static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EmailApp/Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func save(_ draft: Draft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: url(for: draft.id), options: .atomic)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static func loadAll() -> [Draft] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Draft.self, from: $0) }
            .sorted { $0.lastModified > $1.lastModified }
    }
}
