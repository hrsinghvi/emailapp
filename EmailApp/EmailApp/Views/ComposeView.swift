import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: InboxViewModel
    let context: InboxViewModel.ComposeContext

    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var isSending = false
    @State private var errorText: String?

    private var titleText: String {
        switch context {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }

    private var toIsFixed: Bool {
        switch context {
        case .reply, .replyAll: return true
        case .new, .forward: return false
        }
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
                .frame(minHeight: 160)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            AttachmentCardView(
                                filename: attachment.filename,
                                sizeMB: attachment.sizeMB,
                                thumbnail: thumbnail(for: attachment),
                                systemIconName: AttachmentIcon.systemName(forMimeType: attachment.mimeType),
                                onRemove: { attachments.removeAll { $0.id == attachment.id } }
                            )
                        }
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(isSending)

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
        .frame(width: 480, height: 460)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: "#191919").opacity(0.35)
                WindowConfigurator()
            }
        )
        .onAppear(perform: prefill)
    }

    private func prefill() {
        switch context {
        case .new:
            break
        case .reply(let message):
            to = message.senderEmail
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        case .replyAll(let message):
            var seen = Set<String>()
            let recipients = ([message.senderEmail] + message.toRecipients + message.ccRecipients)
                .filter { seen.insert($0.lowercased()).inserted }
            to = recipients.joined(separator: ", ")
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        case .forward(let message):
            subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
            messageBody =
                "\n\n---------- Forwarded message ----------\nFrom: \(message.senderName) <\(message.senderEmail)>\nSubject: \(message.subject)\n\n\(message.body)"
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data))
        }
    }

    private func thumbnail(for attachment: OutgoingAttachment) -> NSImage? {
        guard attachment.mimeType.hasPrefix("image/") else { return nil }
        return NSImage(data: attachment.data)
    }

    private func send() async {
        isSending = true
        errorText = nil
        do {
            switch context {
            case .new, .forward:
                try await vm.send(to: to, subject: subject, body: messageBody, attachments: attachments)
            case .reply(let message):
                try await vm.reply(to: message, body: messageBody, attachments: attachments)
            case .replyAll(let message):
                try await vm.replyAll(to: message, body: messageBody, attachments: attachments)
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
