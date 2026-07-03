import SwiftUI
import WebKit

/// Renders sanitized HTML email content. JS execution is disabled at the
/// engine level (`allowsContentJavaScript = false`) — real defense, not just
/// the text-level stripping in `HTMLSanitizer`. Self-sizes to its content
/// height via `height` so it can live inside a normal SwiftUI `ScrollView`
/// without a nested scroll view fighting it.
///
/// `messageId` lets this reuse a `WKWebView` that `HTMLPrewarmCache` already
/// started loading in the background — the whole point being that by the
/// time this view actually mounts, the content (and its measured height)
/// are already there instead of the load starting at click-time.
struct HTMLBodyView: NSViewRepresentable {
    let messageId: UUID
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        if let cached = HTMLPrewarmCache.shared.webView(for: messageId) {
            cached.navigationDelegate = context.coordinator
            return cached
        }
        let webView = Self.makeConfiguredWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let cachedHeight = HTMLPrewarmCache.shared.height(for: messageId), height != cachedHeight {
            DispatchQueue.main.async { height = cachedHeight }
        }
        // Already loaded via prewarm (or a prior mount of this same view) —
        // reloading would just re-trigger the whole fetch/layout for no reason.
        guard !HTMLPrewarmCache.shared.isLoaded(messageId) else { return }
        webView.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    static func makeConfiguredWebView() -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .clear
        return webView
    }

    /// Most HTML email is authored on a white canvas with no dark-mode
    /// awareness. Rather than hand-picking colors (which fights whatever the
    /// template already declared and produces exactly the inconsistent
    /// look this replaced), invert the whole rendered document's lightness
    /// in one compositing pass — same technique Mail.app uses. Hue is
    /// preserved, images/logos are handled correctly by WebKit's own
    /// implementation, and it naturally makes every element (cards, tables,
    /// buttons) read as one consistent dark surface instead of clashing
    /// light-on-dark boxes.
    /// Sanitizes internally so every caller — the live view and the
    /// prewarm cache alike — is guaranteed to go through it. Two separate
    /// call sites each remembering to sanitize first is exactly how that
    /// step quietly gets skipped on one path.
    static func wrap(_ rawBody: String) -> String {
        let body = HTMLSanitizer.sanitize(rawBody)
        let invertRule = HTMLDarkModeHeuristic.isAlreadyDark(body)
            ? ""
            : "html { -apple-color-filter: apple-invert-lightness(); }"
        return """
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body { background: transparent !important; margin: 0; padding: 0; }
        body { font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 14px;
               word-wrap: break-word; overflow-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        * { max-width: 100%; box-sizing: border-box; }
        \(invertRule)
        </style>
        </head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLBodyView
        init(_ parent: HTMLBodyView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            HTMLPrewarmCache.shared.markLoaded(parent.messageId)
            measureHeight(webView)
            // Images/webfonts often finish loading just after the DOM
            // itself does, reflowing the page a moment later — catch that
            // instead of leaving the card visibly too short until it does.
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let webView else { return }
                    self?.measureHeight(webView)
                }
            }
        }

        private func measureHeight(_ webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let self else { return }
                let measured: CGFloat?
                if let d = result as? Double { measured = CGFloat(d) }
                else if let n = result as? NSNumber { measured = CGFloat(truncating: n) }
                else { measured = nil }
                // Ignore no-op/rounding-noise updates so a settled layout
                // doesn't keep re-triggering the fade/resize animation.
                guard let measured, measured > 0, abs(measured - self.parent.height) > 2 else { return }
                HTMLPrewarmCache.shared.updateHeight(measured, for: self.parent.messageId)
                DispatchQueue.main.async { self.parent.height = measured }
            }
        }

        /// Email links open in the user's real browser instead of navigating
        /// away inside the reading pane.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
