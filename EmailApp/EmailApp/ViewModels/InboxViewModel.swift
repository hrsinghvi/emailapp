import Observation
import SwiftUI

@Observable
final class InboxViewModel {
    var accounts: [Account]
    var categories: [MailCategory]
    var messages: [Message]

    var selectedMessageId: UUID?
    var selectedFolder: String = "inbox"
    var providerFilter: Provider?
    var searchText: String = ""

    init() {
        let gmail = Account(
            id: UUID(),
            provider: .gmail,
            email: "hritvik@gmail.com",
            displayName: "Hritvik Singhvi"
        )
        let outlook = Account(
            id: UUID(),
            provider: .outlook,
            email: "hsinghvi@illinois.edu",
            displayName: "Hritvik Singhvi (UIUC)"
        )
        accounts = [gmail, outlook]

        let jobSearch = MailCategory(id: UUID(), name: "Job search", colorHex: "#b58ee0", isSystem: false)
        let uiuc = MailCategory(id: UUID(), name: "UIUC", colorHex: "#6bb5a0", isSystem: false)
        let miami = MailCategory(id: UUID(), name: "Miami trip", colorHex: "#e0b06b", isSystem: false)
        categories = [jobSearch, uiuc, miami]

        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        messages = [
            // Job search
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "Sarah Chen", senderEmail: "sarah.chen@stripe.com",
                subject: "Your Stripe interview — next steps",
                snippet: "Thanks for taking the time to speak with our team last week. We'd love to move you forward…",
                body: """
                Hi Hritvik,

                Thanks for taking the time to speak with our team last week. The panel was really impressed with your systems background and we'd love to move you forward to the final onsite round.

                The onsite would be four sessions: two coding, one system design, and a behavioral with the hiring manager. We can host you in San Francisco or run it fully remote — whichever works best for you.

                Let me know a few dates that work over the next two weeks and I'll get everything scheduled.

                Best,
                Sarah
                """,
                receivedAt: ago(2), isRead: false, isArchived: false, categoryId: jobSearch.id
            ),
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "LinkedIn Jobs", senderEmail: "jobs-noreply@linkedin.com",
                subject: "8 new jobs matching \"iOS Engineer\"",
                snippet: "Based on your profile, here are new roles at companies you might like…",
                body: """
                Hi Hritvik,

                Based on your profile and saved searches, here are 8 new iOS Engineer roles posted this week:

                • Senior iOS Engineer — Notion (Remote)
                • Mobile Engineer — Ramp (New York, NY)
                • iOS Developer — Robinhood (Menlo Park, CA)

                See all matches and apply directly from your feed.

                — The LinkedIn Jobs Team
                """,
                receivedAt: ago(20), isRead: true, isArchived: false, categoryId: jobSearch.id
            ),
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "Marcus Webb", senderEmail: "mwebb@databricks.com",
                subject: "Referral — Databricks Platform team",
                snippet: "Great chatting at the meetup. I went ahead and submitted a referral for you…",
                body: """
                Hey Hritvik,

                Great chatting at the meetup on Thursday. As promised, I went ahead and submitted a referral for you to the Platform team here at Databricks.

                You should get an automated email from our recruiting system within a day or two. If you don't hear anything by Friday, ping me and I'll nudge the recruiter directly.

                Good luck — I think you'd be a strong fit.

                Marcus
                """,
                receivedAt: ago(46), isRead: false, isArchived: false, categoryId: jobSearch.id
            ),
            Message(
                id: UUID(), accountId: outlook.id, provider: .outlook,
                senderName: "Google Recruiting", senderEmail: "recruiting@google.com",
                subject: "Application received — SWE, University Grad",
                snippet: "We've received your application and it's currently under review by our team…",
                body: """
                Hello Hritvik,

                Thank you for applying to the Software Engineer, University Graduate role at Google. We've received your application and it is currently under review.

                Our team reviews applications on a rolling basis. If your background matches what we're looking for, a recruiter will reach out to schedule an initial conversation.

                Warm regards,
                Google University Programs
                """,
                receivedAt: ago(62), isRead: true, isArchived: false, categoryId: jobSearch.id
            ),

            // UIUC
            Message(
                id: UUID(), accountId: outlook.id, provider: .outlook,
                senderName: "Prof. Tandy Warnow", senderEmail: "warnow@illinois.edu",
                subject: "CS 581 — project proposal feedback",
                snippet: "I read through your proposal on phylogenetic tree estimation. Overall strong, a few notes…",
                body: """
                Hritvik,

                I read through your project proposal on scalable phylogenetic tree estimation. Overall it's a strong direction and clearly scoped.

                Two notes: first, I'd narrow the datasets to the three you can actually finish benchmarking before the deadline. Second, make sure to compare against the FastTree baseline, not just the exact method — otherwise the runtime story won't land.

                Come by office hours Wednesday if you want to talk it through.

                Best,
                Prof. Warnow
                """,
                receivedAt: ago(6), isRead: false, isArchived: false, categoryId: uiuc.id
            ),
            Message(
                id: UUID(), accountId: outlook.id, provider: .outlook,
                senderName: "UIUC Registrar", senderEmail: "registrar@illinois.edu",
                subject: "Fall 2026 registration opens Monday",
                snippet: "Your enrollment time ticket for Fall 2026 is now available in Self-Service…",
                body: """
                Dear Student,

                Your enrollment time ticket for Fall 2026 is now available. Registration opens Monday, July 6 at 7:00 AM.

                Please review any holds on your account before your registration window, as unresolved holds will prevent enrollment. Advising holds can be cleared by meeting with your academic advisor.

                Office of the Registrar
                University of Illinois Urbana-Champaign
                """,
                receivedAt: ago(28), isRead: true, isArchived: false, categoryId: uiuc.id
            ),
            Message(
                id: UUID(), accountId: outlook.id, provider: .outlook,
                senderName: "ACM @ UIUC", senderEmail: "acm@illinois.edu",
                subject: "HackIllinois planning meeting this week",
                snippet: "We're kicking off planning for next year's HackIllinois. First committee meeting is Thursday…",
                body: """
                Hey everyone,

                We're kicking off planning for next year's HackIllinois! The first committee meeting is this Thursday at 6 PM in Siebel 1404.

                We're looking for leads across logistics, sponsorship, and tech infrastructure. If you were part of the team last year, we'd love to have you back in a lead role.

                Pizza will be provided. See you there!

                — ACM Exec
                """,
                receivedAt: ago(51), isRead: false, isArchived: false, categoryId: uiuc.id
            ),

            // Miami trip
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "American Airlines", senderEmail: "notify@aa.com",
                subject: "Your trip to Miami — check in now open",
                snippet: "Check-in is now open for your flight AA 1523 from Chicago O'Hare to Miami…",
                body: """
                Hi Hritvik,

                Check-in is now open for your upcoming trip.

                Flight AA 1523
                Chicago O'Hare (ORD) → Miami (MIA)
                Departs: Fri 8:15 AM · Gate B7
                Confirmation: KXT9PL

                Check in now to select your seat and get your mobile boarding pass. Bag drop closes 45 minutes before departure.

                Safe travels,
                American Airlines
                """,
                receivedAt: ago(4), isRead: false, isArchived: false, categoryId: miami.id
            ),
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "Airbnb", senderEmail: "automated@airbnb.com",
                subject: "Reservation confirmed — Miami Beach",
                snippet: "Your stay at Diego's oceanfront condo is confirmed. Here are your check-in details…",
                body: """
                Your reservation is confirmed!

                Diego's Oceanfront Condo · Miami Beach
                Check-in: Friday after 3:00 PM
                Check-out: Monday before 11:00 AM

                Diego will send the door code the morning of your arrival. The building has a rooftop pool and parking is included — just give your name at the garage.

                Have a great trip,
                The Airbnb Team
                """,
                receivedAt: ago(30), isRead: true, isArchived: false, categoryId: miami.id
            ),
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "Priya Nair", senderEmail: "priya.nair22@gmail.com",
                subject: "Miami plans!! 🌴",
                snippet: "Ok I made a rough itinerary — beach Saturday, that Cuban place Sunday. Thoughts?",
                body: """
                Hritviiik,

                Ok I made a rough itinerary for the weekend:

                Saturday — beach all morning, then that rooftop bar in South Beach everyone keeps posting about.
                Sunday — the Cuban place in Little Havana for brunch, then Wynwood walls in the afternoon.

                Nothing's booked so we can move stuff around. Also Dev might drive down from Orlando to join Saturday night. Thoughts?

                Can't wait!!
                Priya
                """,
                receivedAt: ago(53), isRead: false, isArchived: false, categoryId: miami.id
            ),

            // Uncategorized
            Message(
                id: UUID(), accountId: gmail.id, provider: .gmail,
                senderName: "GitHub", senderEmail: "noreply@github.com",
                subject: "[emailapp] Your Codespace has been stopped",
                snippet: "We stopped your Codespace \"scaling-guacamole\" after 30 minutes of inactivity…",
                body: """
                Hi hritvik,

                We stopped your Codespace "scaling-guacamole" after 30 minutes of inactivity to save you compute hours.

                Your changes are safe. You can restart the Codespace anytime from the repository page or via the CLI with `gh codespace code`.

                Thanks,
                GitHub
                """,
                receivedAt: ago(12), isRead: true, isArchived: false, categoryId: nil
            ),
        ]
    }

    var selectedMessage: Message? {
        guard let id = selectedMessageId else { return nil }
        return messages.first { $0.id == id }
    }

    var filteredMessages: [Message] {
        messages
            .filter { $0.folder == selectedFolder }
            .filter { providerFilter == nil || $0.provider == providerFilter }
            .filter { message in
                guard !searchText.isEmpty else { return true }
                let q = searchText.lowercased()
                return message.subject.lowercased().contains(q)
                    || message.senderName.lowercased().contains(q)
                    || message.snippet.lowercased().contains(q)
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    var groupedByCategory: [(category: MailCategory?, messages: [Message])] {
        let msgs = filteredMessages
        var groups: [(category: MailCategory?, messages: [Message])] = []
        for category in categories {
            let inCategory = msgs.filter { $0.categoryId == category.id }
            if !inCategory.isEmpty {
                groups.append((category, inCategory))
            }
        }
        let uncategorized = msgs.filter { $0.categoryId == nil }
        if !uncategorized.isEmpty {
            groups.append((nil, uncategorized))
        }
        return groups
    }

    func unreadCount(for categoryId: UUID?) -> Int {
        filteredMessages.filter { $0.categoryId == categoryId && !$0.isRead }.count
    }

    func count(for categoryId: UUID?) -> Int {
        filteredMessages.filter { $0.categoryId == categoryId }.count
    }

    func select(_ message: Message) {
        selectedMessageId = message.id
        markRead(message)
    }

    func markRead(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isRead = true
    }

    func toggleArchive(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isArchived.toggle()
    }

    /// Interactive Gmail sign-in + inbox fetch. Merges live mail alongside the
    /// mock data (deduped by stable id). UI wiring happens in the next subtask.
    func loadGmail() async {
        do {
            let account = try await OAuthManager.shared.signInWithGoogle()
            let token = try await OAuthManager.shared.validAccessToken(for: account)
            let fetched = try await GmailAPI.fetchInbox(for: account, accessToken: token)
            if !accounts.contains(where: { $0.email == account.email }) {
                accounts.append(account)
            }
            let existing = Set(messages.map(\.id))
            messages.append(contentsOf: fetched.filter { !existing.contains($0.id) })
        } catch {
            print("Gmail load failed: \(error.localizedDescription)")
        }
    }
}
