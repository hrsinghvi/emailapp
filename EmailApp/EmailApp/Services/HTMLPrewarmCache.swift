import WebKit

/// Keeps a small pool of already-loaded `WKWebView`s keyed by message id.
/// `WKWebView` renders and measures content fine while completely detached
/// from any window, so prewarming just means: create it and call
/// `loadHTMLString` early (when the message list loads, or when a thread
/// next to the one just opened becomes a likely next click) instead of
/// waiting until the reading pane actually mounts the view. By the time the
/// user clicks, the content — and its measured height — are already there.
@MainActor
final class HTMLPrewarmCache {
    static let shared = HTMLPrewarmCache()
    private init() {}

    private final class Entry {
        let webView: WKWebView
        /// Strong reference — `WKWebView.navigationDelegate` is weak, and
        /// this is the only thing keeping it alive during the prewarm load.
        let delegate: PrewarmNavDelegate
        var height: CGFloat = 0
        var isLoaded = false
        init(webView: WKWebView, delegate: PrewarmNavDelegate) {
            self.webView = webView
            self.delegate = delegate
        }
    }

    private final class PrewarmNavDelegate: NSObject, WKNavigationDelegate {
        let messageId: UUID
        weak var cache: HTMLPrewarmCache?
        init(messageId: UUID, cache: HTMLPrewarmCache) {
            self.messageId = messageId
            self.cache = cache
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            cache?.markLoaded(messageId)
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak cache] result, _ in
                let height: CGFloat?
                if let d = result as? Double { height = CGFloat(d) }
                else if let n = result as? NSNumber { height = CGFloat(truncating: n) }
                else { height = nil }
                if let height, height > 0 {
                    Task { @MainActor in cache?.updateHeight(height, for: self.messageId) }
                }
            }
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var lruOrder: [UUID] = []
    private let capacity = 15

    func clear() {
        entries.removeAll()
        lruOrder.removeAll()
    }

    func webView(for messageId: UUID) -> WKWebView? {
        entries[messageId]?.webView
    }

    func isLoaded(_ messageId: UUID) -> Bool {
        entries[messageId]?.isLoaded ?? false
    }

    func height(for messageId: UUID) -> CGFloat? {
        let height = entries[messageId]?.height ?? 0
        return height > 0 ? height : nil
    }

    func markLoaded(_ messageId: UUID) {
        entries[messageId]?.isLoaded = true
    }

    func updateHeight(_ height: CGFloat, for messageId: UUID) {
        entries[messageId]?.height = height
    }

    /// No-ops if already prewarmed — safe to call repeatedly as the list
    /// reloads or scrolls.
    func prewarm(messageId: UUID, html: String) {
        if entries[messageId] != nil {
            touch(messageId)
            return
        }
        let webView = HTMLBodyView.makeConfiguredWebView()
        let delegate = PrewarmNavDelegate(messageId: messageId, cache: self)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(HTMLBodyView.wrap(html), baseURL: nil)

        entries[messageId] = Entry(webView: webView, delegate: delegate)
        lruOrder.append(messageId)
        evictIfNeeded()
    }

    private func touch(_ messageId: UUID) {
        lruOrder.removeAll { $0 == messageId }
        lruOrder.append(messageId)
    }

    private func evictIfNeeded() {
        while lruOrder.count > capacity {
            let oldest = lruOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
