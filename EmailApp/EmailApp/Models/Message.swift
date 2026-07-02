import Foundation

struct Message: Identifiable, Hashable {
    let id: UUID
    let accountId: UUID
    let provider: Provider
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let receivedAt: Date
    var isRead: Bool
    var isArchived: Bool
    var categoryId: UUID?
    var folder: String = "inbox"

    var senderInitials: String {
        senderName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}
