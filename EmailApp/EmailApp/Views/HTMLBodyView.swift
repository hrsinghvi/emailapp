import SwiftUI
import WebKit

/// Renders sanitized HTML email content. JS execution is disabled at the
/// engine level (`allowsContentJavaScript = false`) — real defense, not just
/// the text-level stripping in `HTMLSanitizer`. Self-sizes to its content
/// height via `height` so it can live inside a normal SwiftUI `ScrollView`
/// without a nested scroll view fighting it.
struct HTMLBodyView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.loadHTMLString(Self.wrap(html), baseURL: nil)
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
    private static func wrap(_ body: String) -> String {
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
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let self else { return }
                let measured: CGFloat?
                if let d = result as? Double { measured = CGFloat(d) }
                else if let n = result as? NSNumber { measured = CGFloat(truncating: n) }
                else { measured = nil }
                if let measured, measured > 0 {
                    DispatchQueue.main.async { self.parent.height = measured }
                }
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
