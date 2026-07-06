import SwiftUI

/// qwen2.5 reliably emits Markdown (### headings, "- " bullets, **bold**)
/// even though we never asked for it — `Text(String)` renders that as
/// literal hashes/dashes. `Text(LocalizedStringKey)` already understands
/// inline emphasis (**bold**, *italic*), so this only needs to translate
/// the two block-level constructs it doesn't handle (headings, bullets)
/// into something LocalizedStringKey renders correctly, then let SwiftUI
/// parse the rest.
func markdownFriendly(_ raw: String) -> LocalizedStringKey {
    let lines = raw.components(separatedBy: "\n").map { line -> String in
        if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            return "**\(line[range.upperBound...])**"
        }
        if let range = line.range(of: #"^[-*]\s+"#, options: .regularExpression) {
            return "• \(line[range.upperBound...])"
        }
        return line
    }
    return LocalizedStringKey(lines.joined(separator: "\n"))
}

/// Inline panel (not a sheet/popover) below the toolbar, same window —
/// opened from DetailToolbar's "Ask AI" pill (3b) or ThreadRow's right-click
/// "Ask about this email" (3e). Context is always the currently open
/// thread's messages.
struct AskAIPanel: View {
    @Bindable var vm: InboxViewModel
    let thread: MessageThread

    @State private var question = ""
    @State private var answer = ""
    @State private var isStreaming = false
    @State private var ollamaAvailable = true
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ask AI", systemImage: "sparkle")
                    .font(.appSubheadline.weight(.semibold))
                Spacer()
                Text("qwen2.5 · local")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.appHover))
                Button {
                    streamTask?.cancel()
                    vm.isAskAIPanelPresented = false
                } label: {
                    Image(systemName: "xmark").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            }

            if !ollamaAvailable {
                Text("Ollama isn't running — start it locally to use Ask AI.")
                    .font(.appCaption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                TextField("Ask about this email…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.appSubheadline)
                    .focused($isFieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { ask() }

                Button {
                    ask()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.custom("Inter", size: 20))
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(question.isEmpty ? .secondary : Color.appAccent)
                .disabled(question.isEmpty || isStreaming)
            }

            if isStreaming || !answer.isEmpty {
                ScrollView {
                    Text(markdownFriendly(answer))
                        .font(.appBody)
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(14)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .aiGradientBorder(cornerRadius: 12)
        .task { ollamaAvailable = await AIService.isAvailable() }
        .onAppear { isFieldFocused = true }
    }

    private func ask() {
        guard !question.isEmpty, !isStreaming else { return }
        answer = ""
        isStreaming = true
        let asked = question
        streamTask = Task {
            do {
                try await AIService.askAboutEmail(question: asked, thread: thread.messages) { token in
                    answer += token
                }
            } catch {
                if !Task.isCancelled { answer = "Couldn't reach Ollama: \(error.localizedDescription)" }
            }
            isStreaming = false
        }
    }
}

/// 3c — same full-width slot above the subject line as `AskAIPanel` (was
/// previously a small popover anchored to the toolbar button, which read as
/// "broken" since it could render clipped/offscreen there). Opened from
/// DetailToolbar's "Summarize" pill; generates immediately on appear.
struct SummarizePanel: View {
    @Bindable var vm: InboxViewModel
    let thread: MessageThread

    @State private var summary = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Summarize", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.appSubheadline.weight(.semibold))
                Spacer()
                Text("qwen2.5 · local")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.appHover))
                Button {
                    vm.isSummarizePanelPresented = false
                } label: {
                    Image(systemName: "xmark").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            }

            if let errorText {
                Text(errorText).font(.appCaption).foregroundStyle(.orange)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.appCaption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(markdownFriendly(summary))
                        .font(.appBody)
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(14)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .aiGradientBorder(cornerRadius: 12)
        .task(id: thread.id) { await summarize() }
    }

    private func summarize() async {
        isLoading = true
        errorText = nil
        do {
            summary = try await AIService.summarizeThread(thread.messages)
        } catch {
            errorText = "Couldn't reach Ollama: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
