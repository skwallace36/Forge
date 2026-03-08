import AppKit
import WebKit

/// A live Markdown preview pane using WKWebView.
/// Renders Markdown source as HTML with a dark theme matching the editor.
class MarkdownPreviewView: NSView {

    private let webView: WKWebView
    private var lastRenderedText: String = ""

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews() {
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Update the preview with new Markdown source text.
    /// Only re-renders if the text actually changed.
    func updateMarkdown(_ markdown: String) {
        guard markdown != lastRenderedText else { return }
        lastRenderedText = markdown

        let html = Self.renderHTML(from: markdown)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Markdown → HTML

    /// Convert Markdown to HTML with a dark-themed stylesheet.
    /// Uses a basic regex-based converter for common Markdown constructs.
    private static func renderHTML(from markdown: String) -> String {
        var html = escapeHTML(markdown)

        // Code blocks (fenced with ```)
        html = html.replacingOccurrences(
            of: "```(\\w*)\n([\\s\\S]*?)```",
            with: "<pre><code class=\"language-$1\">$2</code></pre>",
            options: .regularExpression
        )

        // Inline code
        html = html.replacingOccurrences(
            of: "`([^`]+)`",
            with: "<code>$1</code>",
            options: .regularExpression
        )

        // Headers
        html = html.replacingOccurrences(of: "(?m)^######\\s+(.+)$", with: "<h6>$1</h6>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^#####\\s+(.+)$", with: "<h5>$1</h5>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^####\\s+(.+)$", with: "<h4>$1</h4>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^###\\s+(.+)$", with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^##\\s+(.+)$", with: "<h2>$1</h2>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^#\\s+(.+)$", with: "<h1>$1</h1>", options: .regularExpression)

        // Bold and italic
        html = html.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)

        // Strikethrough
        html = html.replacingOccurrences(of: "~~(.+?)~~", with: "<del>$1</del>", options: .regularExpression)

        // Horizontal rules
        html = html.replacingOccurrences(of: "(?m)^---+$", with: "<hr>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^\\*\\*\\*+$", with: "<hr>", options: .regularExpression)

        // Unordered lists
        html = html.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+(.+)$", with: "<li>$1</li>", options: .regularExpression)

        // Ordered lists
        html = html.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+(.+)$", with: "<li>$1</li>", options: .regularExpression)

        // Wrap consecutive <li> items in <ul>
        html = html.replacingOccurrences(of: "(<li>.*?</li>\n?)+", with: "<ul>$0</ul>", options: .regularExpression)

        // Links
        html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)

        // Images
        html = html.replacingOccurrences(of: "!\\[([^\\]]*?)\\]\\(([^)]+)\\)", with: "<img src=\"$2\" alt=\"$1\" style=\"max-width:100%;\">", options: .regularExpression)

        // Blockquotes
        html = html.replacingOccurrences(of: "(?m)^&gt;\\s+(.+)$", with: "<blockquote>$1</blockquote>", options: .regularExpression)

        // Paragraphs: wrap lines separated by blank lines
        html = html.replacingOccurrences(of: "\n\n", with: "</p><p>")
        html = "<p>" + html + "</p>"

        // Clean up empty paragraphs and fix nested block elements
        html = html.replacingOccurrences(of: "<p></p>", with: "")
        html = html.replacingOccurrences(of: "<p>(<h[1-6]>)", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "(</h[1-6]>)</p>", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "<p>(<pre>)", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "(</pre>)</p>", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "<p>(<ul>)", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "(</ul>)</p>", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "<p>(<hr>)", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "(<hr>)</p>", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "<p>(<blockquote>)", with: "$1", options: .regularExpression)
        html = html.replacingOccurrences(of: "(</blockquote>)</p>", with: "$1", options: .regularExpression)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: #d4d4d4;
            background-color: #1e1f21;
            padding: 16px 24px;
            margin: 0;
        }
        h1, h2, h3, h4, h5, h6 {
            color: #e0e0e0;
            margin-top: 1.2em;
            margin-bottom: 0.4em;
            font-weight: 600;
        }
        h1 { font-size: 1.8em; border-bottom: 1px solid #333; padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid #333; padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; }
        a { color: #569cd6; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: 'SF Mono', Menlo, monospace;
            font-size: 0.9em;
            background-color: #2a2d30;
            padding: 2px 6px;
            border-radius: 3px;
        }
        pre {
            background-color: #1a1b1d;
            border: 1px solid #333;
            border-radius: 6px;
            padding: 12px 16px;
            overflow-x: auto;
        }
        pre code {
            background: none;
            padding: 0;
        }
        blockquote {
            border-left: 3px solid #444;
            margin-left: 0;
            padding-left: 16px;
            color: #999;
        }
        hr {
            border: none;
            border-top: 1px solid #333;
            margin: 1.5em 0;
        }
        ul, ol { padding-left: 24px; }
        li { margin: 4px 0; }
        img { border-radius: 4px; }
        strong { color: #e0e0e0; }
        del { color: #888; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 1em 0;
        }
        th, td {
            border: 1px solid #333;
            padding: 8px 12px;
            text-align: left;
        }
        th { background-color: #2a2d30; }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
