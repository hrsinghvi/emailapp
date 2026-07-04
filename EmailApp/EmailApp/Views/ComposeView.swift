import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    let vm: InboxViewModel
    let context: InboxViewModel.ComposeContext
    /// Floats as a non-modal panel (Gmail-style), not a `.sheet` — so there's
    /// no `\.dismiss` environment value to close it with.
    let onClose: () -> Void

    @State private var draftId = UUID()
    @State private var origin: DraftOrigin = .new
    @State private var toEmails: [String] = []
    @State private var ccEmails: [String] = []
    @State private var bccEmails: [String] = []
    @State private var showCcBcc = false
    @State private var subject = ""
    @State private var attributedBody = NSAttributedString(string: "")
    @State private var attachments: [OutgoingAttachment] = []
    @State private var showLinkPrompt = false
    @State private var linkText = ""
    @State private var linkURL = ""
    @State private var hasSavedOnce = false

    @State private var editorController = RichTextEditorController()
    @State private var escapeMonitor: Any?

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

    /// A fresh reply/reply-all locks "To" to the original sender — but once
    /// it's saved as a draft and reopened, it's the user's own in-progress
    /// message and every field (recipient included) should be editable.
    private var toIsFixed: Bool {
        if case .draft = context { return false }
        switch origin {
        case .reply, .replyAll: return true
        case .new, .forward: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(titleText)
                    .font(.appSubheadline.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .iconButtonHitArea()
                }
                .buttonStyle(.plain)
            }

            // Each field's suggestion dropdown floats via .overlay — needs
            // a zIndex here (at the sibling level in this VStack) or it
            // paints behind whichever field comes after it, same issue the
            // search bar's dropdown had against the toolbar below it.
            RecipientChipField(placeholder: "To", emails: $toEmails, isDisabled: toIsFixed)
                .zIndex(3)

            if showCcBcc {
                RecipientChipField(placeholder: "Cc", emails: $ccEmails)
                    .zIndex(2)
                RecipientChipField(placeholder: "Bcc", emails: $bccEmails)
                    .zIndex(1)
            } else {
                Button("Add Cc/Bcc") { showCcBcc = true }
                    .buttonStyle(.plain)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            field("Subject", text: $subject)

            FormattingToolbar(controller: editorController, onInsertLink: { showLinkPrompt = true }, onInsertImage: pickInlineImage, onAttachFile: pickAttachments)

            RichTextEditor(attributedText: $attributedBody, controller: editorController)
                .frame(minHeight: 180)
                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            AttachmentCardView(
                                filename: attachment.filename,
                                sizeMB: attachment.sizeMB,
                                thumbnail: thumbnail(for: attachment),
                                systemIconName: AttachmentIcon.systemName(forMimeType: attachment.mimeType),
                                onRemove: {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            )
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                }
            }

            HStack {
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.appSubheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Circle().fill(Color.appHover))
                }
                .buttonStyle(.plain)

                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button {
                    send()
                } label: {
                    Text("Send")
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.appAccent.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .disabled(toEmails.isEmpty || subject.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 720)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .onAppear(perform: prefill)
        .onAppear {
            // SwiftUI's .onKeyPress doesn't reliably see Escape when focus
            // is inside the rich text editor's underlying NSTextView (it's
            // its own first responder and can swallow the key before it
            // ever reaches SwiftUI's responder chain) — a local NSEvent
            // monitor intercepts it regardless of which control has focus.
            // onClose() -> ComposeView disappears -> onDisappear's autosave
            // already only saves a draft if something's actually been
            // entered, so empty compose just closes with no leftover draft.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Let the link-insert sheet handle its own Escape/Cancel
                // instead of closing the whole compose window underneath it.
                guard event.keyCode == 53, !showLinkPrompt else { return event }
                onClose()
                return nil
            }
        }
        .onDisappear {
            autosave()
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                autosave()
            }
        }
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
            attributedBody = signatureAttributedString(forAccount: vm.accounts.first)
        case .reply(let message):
            origin = .reply(messageId: message.id)
            toEmails = [message.senderEmail]
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
            attributedBody = signatureAttributedString(forAccount: vm.accounts.first { $0.id == message.accountId })
        case .replyAll(let message):
            origin = .replyAll(messageId: message.id)
            var seen = Set<String>()
            toEmails = ([message.senderEmail] + message.toRecipients + message.ccRecipients)
                .filter { seen.insert($0.lowercased()).inserted }
            subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
            attributedBody = signatureAttributedString(forAccount: vm.accounts.first { $0.id == message.accountId })
        case .forward(let message):
            origin = .forward(messageId: message.id)
            subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
            let signature = signatureHTML(forAccount: vm.accounts.first { $0.id == message.accountId })
            let quoted = "\(signature)<br><br>---------- Forwarded message ----------<br>From: \(message.senderName) &lt;\(message.senderEmail)&gt;<br>Subject: \(message.subject)<br><br>\(message.htmlBody ?? message.body)"
            attributedBody = NSAttributedString(html: quoted) ?? NSAttributedString(string: quoted)
        case .draft(let draft):
            draftId = draft.id
            origin = draft.origin
            toEmails = Self.splitRecipients(draft.to)
            ccEmails = Self.splitRecipients(draft.cc)
            bccEmails = Self.splitRecipients(draft.bcc)
            showCcBcc = !ccEmails.isEmpty || !bccEmails.isEmpty
            subject = draft.subject
            attributedBody = NSAttributedString(html: draft.bodyHTML) ?? NSAttributedString(string: "")
            attachments = draft.attachments.compactMap(\.outgoing)
            hasSavedOnce = true
        }
    }

    private static func splitRecipients(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func signatureHTML(forAccount account: Account?) -> String {
        guard let email = account?.email, let signature = AppSettings.shared.signatures[email], !signature.isEmpty else {
            return ""
        }
        return "<br><br>\(signature.replacingOccurrences(of: "\n", with: "<br>"))"
    }

    private func signatureAttributedString(forAccount account: Account?) -> NSAttributedString {
        let html = signatureHTML(forAccount: account)
        guard !html.isEmpty else { return NSAttributedString(string: "") }
        return NSAttributedString(html: html) ?? NSAttributedString(string: "")
    }

    private var isCompletelyEmpty: Bool {
        toEmails.isEmpty && ccEmails.isEmpty && bccEmails.isEmpty && subject.isEmpty
            && attributedBody.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// First edit creates the draft; every autosave after that fully
    /// replaces its saved contents so it always reflects what's on screen.
    private func autosave() {
        guard !isCompletelyEmpty else { return }
        hasSavedOnce = true
        vm.saveDraft(
            Draft(
                id: draftId, accountEmail: nil,
                to: toEmails.joined(separator: ", "), cc: ccEmails.joined(separator: ", "), bcc: bccEmails.joined(separator: ", "),
                subject: subject,
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
        withAnimation(.easeOut(duration: 0.2)) {
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data))
            }
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
            to: toEmails.joined(separator: ", "), cc: ccEmails.joined(separator: ", "), bcc: bccEmails.joined(separator: ", "),
            subject: subject, bodyHTML: attributedBody.htmlString(), attachments: attachments
        )
        onClose()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.18)))
    }
}

private struct LinkPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @Binding var url: String
    let onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link").font(.appHeadline)
            TextField("Text", text: $text).textFieldStyle(.roundedBorder)
            TextField("URL", text: $url).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { onInsert(); dismiss() }
                    .disabled(url.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
