import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: InboxViewModel
    let context: InboxViewModel.ComposeContext

    @State private var draftId = UUID()
    @State private var origin: DraftOrigin = .new
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showCcBcc = false
    @State private var subject = ""
    @State private var attributedBody = NSAttributedString(string: "")
    @State private var attachments: [OutgoingAttachment] = []
    @State private var showLinkPrompt = false
    @State private var linkText = ""
    @State private var linkURL = ""
    @State private var hasSavedOnce = false

    @State private var editorController = RichTextEditorController()

    private var titleText: String {
        switch context {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft(let draft):
            switch draft.origin {
            case .new: return "New Message"
            case .reply: return "Reply"
            case .replyAll: return "Reply All"
            case .forward: return "Forward"
            }
        }
    }

    private var toIsFixed: Bool {
        switch origin {
        case .reply, .replyAll: return true
        case .new, .forward: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleText)
                .font(.headline)

            field("To", text: $to)
                .disabled(toIsFixed)

            if showCcBcc {
                field("Cc", text: $cc)
                field("Bcc", text: $bcc)
            } else {
                Button("Add Cc/Bcc") { showCcBcc = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            field("Subject", text: $subject)

            FormattingToolbar(controller: editorController, onInsertLink: { showLinkPrompt = true }, onInsertImage: pickInlineImage, onAttachFile: pickAttachments)

            RichTextEditor(attributedText: $attributedBody, controller: editorController)
                .frame(minHeight: 180)
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

                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button {
                    send()
                } label: {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: "#b58ee0").opacity(0.9)))
                }
                .buttonStyle(.plain)
                .disabled(to.isEmpty || subject.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: "#191919").opacity(0.35)
                WindowConfigurator()
            }
        )
        .onAppear(perform: prefill)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                autosave()
            }
        }
        .onDisappear { autosave() }
        .sheet(isPresented: $showLinkPrompt) {
            LinkPromptView(text: $linkText, url: $linkURL) {
                editorController.insertLink(text: linkText.isEmpty ? linkURL : linkText, url: linkURL)
                linkText = ""
                linkURL = ""
            }
        }
    }

    private func prefill() {
        switch context {
        case .new:
            origin = .new
        case .reply(let message):
            origin = .reply(messageId: message.id)
            to = message.senderEmail
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        case .replyAll(let message):
            origin = .replyAll(messageId: message.id)
            var seen = Set<String>()
            let recipients = ([message.senderEmail] + message.toRecipients + message.ccRecipients)
                .filter { seen.insert($0.lowercased()).inserted }
            to = recipients.joined(separator: ", ")
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        case .forward(let message):
            origin = .forward(messageId: message.id)
            subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
            let quoted = "<br><br>---------- Forwarded message ----------<br>From: \(message.senderName) &lt;\(message.senderEmail)&gt;<br>Subject: \(message.subject)<br><br>\(message.htmlBody ?? message.body)"
            attributedBody = NSAttributedString(html: quoted) ?? NSAttributedString(string: quoted)
        case .draft(let draft):
            draftId = draft.id
            origin = draft.origin
            to = draft.to
            cc = draft.cc
            bcc = draft.bcc
            showCcBcc = !draft.cc.isEmpty || !draft.bcc.isEmpty
            subject = draft.subject
            attributedBody = NSAttributedString(html: draft.bodyHTML) ?? NSAttributedString(string: "")
            attachments = draft.attachments.compactMap(\.outgoing)
            hasSavedOnce = true
        }
    }

    /// First edit creates the draft; every autosave after that fully
    /// replaces its saved contents so it always reflects what's on screen.
    private func autosave() {
        let isEmpty = to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && attributedBody.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        guard !isEmpty else { return }
        hasSavedOnce = true
        vm.saveDraft(
            Draft(
                id: draftId, accountEmail: nil, to: to, cc: cc, bcc: bcc, subject: subject,
                bodyHTML: attributedBody.htmlString(),
                attachments: attachments.map { DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
                origin: origin, lastModified: Date()
            )
        )
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

    private func pickInlineImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.urls.first, let image = NSImage(contentsOf: url) else { return }
        editorController.insertImage(image)
    }

    private func thumbnail(for attachment: OutgoingAttachment) -> NSImage? {
        guard attachment.mimeType.hasPrefix("image/") else { return nil }
        return NSImage(data: attachment.data)
    }

    /// Send is deliberately delayed 8s (Undo Send) — see
    /// `InboxViewModel.queueSend`. The compose window closes immediately;
    /// nothing is transmitted until the window elapses.
    private func send() {
        vm.queueSend(
            draftId: hasSavedOnce ? draftId : nil, origin: origin,
            to: to, cc: cc, bcc: bcc, subject: subject,
            bodyHTML: attributedBody.htmlString(), attachments: attachments
        )
        dismiss()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LinkPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @Binding var url: String
    let onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link").font(.headline)
            TextField("Text", text: $text).textFieldStyle(.roundedBorder)
            TextField("URL", text: $url).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Insert") { onInsert(); dismiss() }
                    .disabled(url.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
