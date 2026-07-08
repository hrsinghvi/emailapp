import AppKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    let vm: InboxViewModel
    let context: InboxViewModel.ComposeContext
    /// Floats as a non-modal panel (Gmail-style), not a `.sheet` — so there's
    /// no `\.dismiss` environment value to close it with.
    let onClose: () -> Void
    /// Lives on `InboxViewModel.ComposeSession`, not local `@State` — the
    /// compose stack needs to read/set it from outside to lay minimized and
    /// open sessions out together, and driving it externally means this
    /// view is never unmounted by minimizing (state — recipients, body,
    /// attachments, AI draft history — stays exactly as it was).
    @Binding var isMinimized: Bool

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

    // 3d — Draft with AI
    @State private var isDraftPromptShown = false
    @State private var draftInstructions = ""
    @State private var isDrafting = false
    @State private var draftError: String?
    @State private var draftTask: Task<Void, Never>?
    @State private var bodyUndoStack: [NSAttributedString] = []
    @State private var bodyRedoStack: [NSAttributedString] = []
    @State private var outgoingPreviewURL: URL?
    /// Flips the AI bar from "Draft with AI" (appends a first pass) to
    /// "Change with AI" (revises what's already there) after the first
    /// successful AI draft — a second "draft" call with fresh instructions
    /// doesn't make sense once there's already AI-authored content to edit.
    @State private var hasDraftedWithAI = false

    private var titleText: String { context.title }

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

    private var isSendDisabled: Bool { toEmails.isEmpty || subject.isEmpty }

    var body: some View {
        Group {
            if isMinimized {
                minimizedBar
            } else {
                fullComposeContent
            }
        }
        .quickLookPreview($outgoingPreviewURL)
        .onAppear(perform: prefill)
        .onAppear { editorController.subjectProvider = { subject } }
        .onAppear { editorController.senderNameProvider = { composeAccount?.displayName ?? "" } }
        .onAppear {
            // Reply/Reply All already have a fixed recipient — the body is
            // the obvious next thing to type, so focus it instead of
            // leaving nothing focused. `.async` since the underlying
            // NSTextView (set by RichTextEditor's makeNSView) may not be
            // attached to its window in the same runloop turn as this
            // onAppear.
            guard toIsFixed else { return }
            DispatchQueue.main.async { editorController.focus() }
        }
        .onAppear {
            // SwiftUI's .onKeyPress doesn't reliably see Escape when focus
            // is inside the rich text editor's underlying NSTextView (it's
            // its own first responder and can swallow the key before it
            // ever reaches SwiftUI's responder chain) — a local NSEvent
            // monitor intercepts it regardless of which control has focus.
            // Escape minimizes (Gmail's behavior) rather than closing —
            // only the header's X actually discards/closes-to-draft. If
            // already minimized there's nothing smaller to collapse to, so
            // the event passes through untouched.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Let the link-insert sheet handle its own Escape/Cancel
                // instead of minimizing the whole compose window underneath it.
                guard event.keyCode == 53, !showLinkPrompt, !isMinimized else { return event }
                withAnimation(.easeOut(duration: 0.15)) { isMinimized = true }
                return nil
            }
        }
        .onChange(of: isMinimized) { _, minimized in
            // Reply/Reply All's autofocus already only fires on first
            // appear — restoring from minimized needs its own trigger since
            // the underlying NSTextView was never actually torn down, just
            // hidden, so nothing else would refocus it.
            guard !minimized, toIsFixed else { return }
            DispatchQueue.main.async { editorController.focus() }
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

    /// Collapsed Gmail-style title bar shown while minimized — tapping it
    /// (or the chevron) restores the full compose window with everything
    /// exactly as it was; only the X here actually closes/discards-to-draft.
    private var minimizedBar: some View {
        HStack(spacing: 12) {
            Text(titleText)
                .font(.appSubheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.15)) { isMinimized = false } } label: {
                Image(systemName: "chevron.up")
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
        }
        .padding(.horizontal, 16)
        .frame(width: 320, height: 52)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.appBorder.opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isMinimized = false } }
    }

    private var fullComposeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(titleText)
                    .font(.appSubheadline.weight(.semibold))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { isMinimized = true } } label: {
                    Image(systemName: "minus")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
            }

            // Each field's suggestion dropdown floats via .overlay — needs
            // a zIndex here (at the sibling level in this VStack) or it
            // paints behind whichever field comes after it, same issue the
            // search bar's dropdown had against the toolbar below it.
            RecipientChipField(placeholder: "To", emails: $toEmails, isDisabled: toIsFixed, autoFocus: !toIsFixed)
                .zIndex(3)

            if showCcBcc {
                RecipientChipField(placeholder: "Cc", emails: $ccEmails)
                    .zIndex(2)
                RecipientChipField(placeholder: "Bcc", emails: $bccEmails)
                    .zIndex(1)
            } else {
                Button("Add Cc/Bcc") { showCcBcc = true }
                    .buttonStyle(.pointerPlain)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            field("Subject", text: $subject)

            FormattingToolbar(controller: editorController, onInsertLink: { showLinkPrompt = true }, onInsertImage: pickInlineImage, onAttachFile: pickAttachments)

            // maxHeight caps how far the compose card itself grows — past
            // this, the NSScrollView already wrapping the editor (see
            // RichTextEditor) takes over and scrolls internally, same as
            // any real compose window. Without a cap here, a long email
            // just kept growing the whole fixed-height card past its own
            // background, pushing Cancel/Send below the visible card
            // entirely instead of ever engaging that internal scroll.
            //
            // The Draft-with-AI bar floats as a bottom-anchored overlay on
            // top of the editor (Gmail's Help-me-write placement) instead of
            // pushing the text down as a sibling — it appears/disappears
            // without reflowing anything else in the compose window.
            ZStack(alignment: .bottom) {
                RichTextEditor(attributedText: $attributedBody, controller: editorController)
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))

                if isDraftPromptShown {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.appCaption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)

                            if isDrafting {
                                Text("Generating…")
                                    .font(.appSubheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                                Spacer()
                                Button {
                                    draftTask?.cancel()
                                    draftTask = nil
                                    isDrafting = false
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.appCaption)
                                        .foregroundStyle(.secondary)
                                        .padding(6)
                                        .background(Circle().fill(Color.appHover))
                                }
                                .buttonStyle(.pointerPlain)
                            } else {
                                // axis: .vertical + lineLimit lets this grow
                                // with its content instead of scrolling a
                                // fixed-height single line.
                                TextField("Describe your change", text: $draftInstructions, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.appSubheadline)
                                    .lineLimit(1...6)
                                    .onSubmit { draftWithAI() }

                                Button {
                                    draftWithAI()
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.appCaption.weight(.semibold))
                                        .foregroundStyle(draftInstructions.isEmpty ? .secondary : Color.black)
                                        .padding(6)
                                        .background(Circle().fill(draftInstructions.isEmpty ? Color.appHover : Color.appAccent))
                                }
                                .buttonStyle(.pointerPlain)
                                .disabled(draftInstructions.isEmpty)
                            }
                        }

                        if !isDrafting {
                            HStack(spacing: 14) {
                                ForEach(AIService.RewriteStyle.allCases, id: \.self) { style in
                                    Button { rewriteBody(style) } label: {
                                        Image(systemName: style.icon)
                                            .font(.appCaption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.pointerPlain)
                                    .disabled(attributedBody.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .help(style.label)
                                }
                                Spacer()
                                Button { undoDraftEdit() } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.appCaption)
                                        .foregroundStyle(bodyUndoStack.isEmpty ? Color.secondary.opacity(0.4) : .secondary)
                                }
                                .buttonStyle(.pointerPlain)
                                .disabled(bodyUndoStack.isEmpty)
                                Button { redoDraftEdit() } label: {
                                    Image(systemName: "arrow.uturn.forward")
                                        .font(.appCaption)
                                        .foregroundStyle(bodyRedoStack.isEmpty ? Color.secondary.opacity(0.4) : .secondary)
                                }
                                .buttonStyle(.pointerPlain)
                                .disabled(bodyRedoStack.isEmpty)
                            }
                        }

                        if let draftError {
                            Text(draftError).font(.appCaption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .aiGradientBorder(cornerRadius: 14)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                    .padding(10)
                }
            }

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
                            // Same click-to-preview convention as incoming
                            // attachments in ReadingPaneView — these bytes
                            // are already in memory (picked from disk), so
                            // no fetch step, just a temp file for QuickLook.
                            .onTapGesture { previewAttachment(attachment) }
                            .pointerOnHover()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .buttonStyle(.pointerPlain)

                if AppSettings.shared.aiFeaturesEnabled {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { isDraftPromptShown.toggle() }
                    } label: {
                        Label(hasDraftedWithAI ? "Change with AI" : "Draft with AI", systemImage: "sparkle")
                            .font(.appSubheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.pointerPlain)
                    .background(Capsule().fill(Color.appHover))
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(colors: Color.aiGradientStops, startPoint: .leading, endPoint: .trailing).opacity(0.55),
                            lineWidth: 1.2
                        )
                    )
                }

                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.pointerPlain)
                    .foregroundStyle(.secondary)
                Button {
                    send()
                } label: {
                    Text("Send")
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundStyle(isSendDisabled ? .secondary : Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isSendDisabled ? Color.appHover : Color.appAccent))
                }
                .buttonStyle(.pointerPlain)
                .disabled(isSendDisabled)
            }
        }
        .padding(20)
        .frame(width: 680, height: 720)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
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

    /// The account this compose session is sending as — same resolution
    /// `prefill()` uses per-context, consolidated here so AI features (3g
    /// autocomplete) know the real sender's name instead of guessing one.
    private var composeAccount: Account? {
        switch context {
        case .new: return vm.accounts.first
        case .reply(let message), .replyAll(let message), .forward(let message):
            return vm.accounts.first { $0.id == message.accountId } ?? vm.accounts.first
        case .draft(let draft):
            return vm.accounts.first { $0.email == draft.accountEmail } ?? vm.accounts.first
        }
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

    /// The message this compose session is replying to/forwarding, if any —
    /// quoted for AI drafting context. Empty for a brand-new message.
    private var quotedThreadMessage: [Message] {
        switch context {
        case .reply(let message), .replyAll(let message), .forward(let message): return [message]
        case .new, .draft: return []
        }
    }

    /// A few of the user's own past sent messages to the current "To"
    /// recipient(s), pulled from the local cache — no network round trip
    /// (see plan 3d: "prefer local").
    private var pastSentMessages: [Message] {
        guard !toEmails.isEmpty else { return [] }
        let myEmails = Set(vm.accounts.map { $0.email.lowercased() })
        let recipients = Set(toEmails.map { $0.lowercased() })
        return vm.messages
            .filter { myEmails.contains($0.senderEmail.lowercased()) && $0.toRecipients.contains { recipients.contains($0.lowercased()) } }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(3)
            .map { $0 }
    }

    private func draftWithAI() {
        guard !draftInstructions.isEmpty, !isDrafting else { return }
        isDrafting = true
        draftError = nil
        let instructions = draftInstructions
        let quoted = quotedThreadMessage
        let pastSent = pastSentMessages
        let previousBody = attributedBody
        // Once there's already AI-authored content, a follow-up instruction
        // means "change what's there," not "write another pass and append
        // it" — the button itself relabels to "Change with AI" for this.
        let isRevision = hasDraftedWithAI
        draftTask = Task {
            do {
                let text = isRevision
                    ? try await AIService.reviseEmail(instructions: instructions, currentBody: previousBody.string)
                    : try await AIService.draftEmail(instructions: instructions, quotedThread: quoted, pastSentToRecipient: pastSent)
                try Task.checkCancellation()
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white]
                )
                pushUndo(previousBody)
                if isRevision {
                    attributedBody = attributed
                } else {
                    let combined = NSMutableAttributedString(attributedString: previousBody)
                    if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
                    combined.append(attributed)
                    attributedBody = combined
                }
                hasDraftedWithAI = true
                isDraftPromptShown = false
                draftInstructions = ""
            } catch is CancellationError {
                // user hit stop — leave the body untouched
            } catch {
                draftError = "Couldn't reach Ollama: \(error.localizedDescription)"
            }
            isDrafting = false
            draftTask = nil
        }
    }

    /// Gmail-style quick-edit icons (polish/formalize/friendly/shorten) —
    /// rewrites the whole body in place rather than appending.
    private func rewriteBody(_ style: AIService.RewriteStyle) {
        guard !isDrafting else { return }
        let currentText = attributedBody.string
        guard !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isDrafting = true
        draftError = nil
        let previousBody = attributedBody
        draftTask = Task {
            do {
                let text = try await AIService.rewrite(text: currentText, style: style)
                try Task.checkCancellation()
                pushUndo(previousBody)
                attributedBody = NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white]
                )
            } catch is CancellationError {
            } catch {
                draftError = "Couldn't reach Ollama: \(error.localizedDescription)"
            }
            isDrafting = false
            draftTask = nil
        }
    }

    private func pushUndo(_ previous: NSAttributedString) {
        bodyUndoStack.append(previous)
        bodyRedoStack.removeAll()
    }

    private func undoDraftEdit() {
        guard let previous = bodyUndoStack.popLast() else { return }
        bodyRedoStack.append(attributedBody)
        attributedBody = previous
    }

    private func redoDraftEdit() {
        guard let next = bodyRedoStack.popLast() else { return }
        bodyUndoStack.append(attributedBody)
        attributedBody = next
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

    /// Real thumbnails for images/PDFs (same two types ReadingPaneView
    /// renders), everything else keeps its generic doc icon.
    private func thumbnail(for attachment: OutgoingAttachment) -> NSImage? {
        if attachment.mimeType == "application/pdf" {
            return PDFDocument(data: attachment.data)?.page(at: 0)?.thumbnail(of: CGSize(width: 168, height: 120), for: .cropBox)
        }
        guard attachment.mimeType.hasPrefix("image/") else { return nil }
        return NSImage(data: attachment.data)
    }

    /// Writes the already-in-memory attachment bytes to a temp file and
    /// hands it to QuickLook — no network fetch needed since, unlike an
    /// incoming attachment, this data was already read from disk when
    /// picked (see `AttachmentPreviewController` for the fetch-then-cache
    /// version incoming attachments need).
    private func previewAttachment(_ attachment: OutgoingAttachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadwellOutgoingPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(attachment.id.uuidString)-\(attachment.filename)")
        guard (try? attachment.data.write(to: url, options: .atomic)) != nil else { return }
        outgoingPreviewURL = url
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
