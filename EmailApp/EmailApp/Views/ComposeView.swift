import SwiftUI

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: InboxViewModel
    let context: InboxViewModel.ComposeContext

    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false
    @State private var errorText: String?

    private var titleText: String {
        switch context {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .forward: return "Forward"
        }
    }

    private var toIsFixed: Bool {
        if case .reply = context { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleText)
                .font(.headline)

            field("To", text: $to)
                .disabled(toIsFixed)
            field("Subject", text: $subject)

            TextEditor(text: $messageBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isSending)
                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 6) {
                        if isSending { ProgressView().controlSize(.small) }
                        Text(isSending ? "Sending…" : "Send")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: "#b58ee0").opacity(0.9)))
                }
                .buttonStyle(.plain)
                .disabled(isSending || to.isEmpty || subject.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .background(Color(hex: "#191919"))
        .onAppear(perform: prefill)
    }

    private func prefill() {
        switch context {
        case .new:
            break
        case .reply(let message):
            to = message.senderEmail
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        case .forward(let message):
            subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
            messageBody =
                "\n\n---------- Forwarded message ----------\nFrom: \(message.senderName) <\(message.senderEmail)>\nSubject: \(message.subject)\n\n\(message.body)"
        }
    }

    private func send() async {
        isSending = true
        errorText = nil
        do {
            switch context {
            case .new, .forward:
                try await vm.send(to: to, subject: subject, body: messageBody)
            case .reply(let message):
                try await vm.reply(to: message, body: messageBody)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isSending = false
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
