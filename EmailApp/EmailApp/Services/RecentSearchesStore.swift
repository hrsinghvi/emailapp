import Foundation

/// Last 10 searches, most recent first, persisted across launches.
enum RecentSearchesStore {
    private static let key = "recentSearches"
    private static let limit = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load()
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        UserDefaults.standard.set(list, forKey: key)
    }
}
