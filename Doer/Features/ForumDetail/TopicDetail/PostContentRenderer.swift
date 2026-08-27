import UIKit
import WebKit

struct InteractiveRegion {
    enum Kind {
        case image(url: URL)
        case link(url: URL)
        case details(index: Int)
    }

    let kind: Kind
    let frame: CGRect
}

struct CodeBlockInfo {
    let frame: CGRect
    let text: String
    let fullWidth: CGFloat
}

private struct WebRenderStyle: Sendable {
    let bodyFontSize: CGFloat
    let quoteFontSize: CGFloat
    let codeFontSize: CGFloat
    let accentHex: String
    let backgroundHex: String
    let mutedBackgroundHex: String
    let quoteBorderHex: String
    let blockquoteBackgroundHex: String
    let bodyFontFamilyCSS: String

    nonisolated static let `default` = WebRenderStyle(
        bodyFontSize: 13.94,
        quoteFontSize: 12.94,
        codeFontSize: 11.94,
        accentHex: "#0079d3",
        backgroundHex: "transparent",
        mutedBackgroundHex: "#f6f8ff",
        quoteBorderHex: "#cccccc",
        blockquoteBackgroundHex: "transparent",
        bodyFontFamilyCSS: "-apple-system, BlinkMacSystemFont, sans-serif"
    )
}

final class PostContentRenderer: NSObject {
    static let shared = PostContentRenderer()
    private var activeWebViews: [WKWebView] = []

    override private init() {
        super.init()
    }

    struct RenderedPost {
        let height: CGFloat
        let snapshot: UIImage?
        let interactiveRegions: [InteractiveRegion]
        let codeBlocks: [CodeBlockInfo]
    }

    func renderPosts(
        _ posts: [DiscourseTopicDetail.Post],
        baseURL: String,
        containerWidth: CGFloat,
        onRendered: ((Int, RenderedPost) -> Void)? = nil
    ) async -> [Int: RenderedPost] {
        let maxConcurrency = 3
        return await withTaskGroup(of: (Int, RenderedPost).self) { group in
            var iterator = posts.makeIterator()

            // Seed the group with up to maxConcurrency tasks
            for _ in 0 ..< min(maxConcurrency, posts.count) {
                if let post = iterator.next() {
                    let isDark = Self.isDarkMode
                    let webStyle = Self.currentWebRenderStyle
                    group.addTask {
                        let html = Self.buildHTML(cooked: post.cooked, baseURL: baseURL, isDark: isDark, webStyle: webStyle)
                        let rendered = await self.renderSinglePost(html: html, baseURL: baseURL, width: containerWidth)
                        return (post.id, rendered)
                    }
                }
            }

            var results: [Int: RenderedPost] = [:]
            for await (id, rendered) in group {
                results[id] = rendered
                onRendered?(id, rendered)
                // Sliding window: add next task when one finishes
                if let post = iterator.next() {
                    let isDark = Self.isDarkMode
                    let webStyle = Self.currentWebRenderStyle
                    group.addTask {
                        let html = Self.buildHTML(cooked: post.cooked, baseURL: baseURL, isDark: isDark, webStyle: webStyle)
                        let rendered = await self.renderSinglePost(html: html, baseURL: baseURL, width: containerWidth)
                        return (post.id, rendered)
                    }
                }
            }
            return results
        }
    }

    /// Re-render a single post with specific <details> elements toggled open.
    func reRenderPost(
        cooked: String,
        baseURL: String,
        width: CGFloat,
        openDetailsIndices: Set<Int>
    ) async -> RenderedPost {
        let html = Self.buildHTML(cooked: cooked, baseURL: baseURL, openDetailsIndices: openDetailsIndices, isDark: Self.isDarkMode, webStyle: Self.currentWebRenderStyle)
        return await renderSinglePost(html: html, baseURL: baseURL, width: width)
    }

    /// Render a single HTML block fragment (used by FallbackBlockView for unsupported blocks).
    func renderHTMLBlock(html: String, baseURL: String, width: CGFloat) async -> RenderedPost {
        let fullHTML = Self.buildHTML(cooked: html, baseURL: baseURL, isDark: Self.isDarkMode, webStyle: Self.currentWebRenderStyle)
        return await renderSinglePost(html: fullHTML, baseURL: baseURL, width: width)
    }

    private func renderSinglePost(html: String, baseURL: String, width: CGFloat) async -> RenderedPost {
        await withCheckedContinuation { continuation in
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
            webView.isOpaque = false
            webView.scrollView.isScrollEnabled = false
            self.activeWebViews.append(webView)

            let delegate = RenderDelegate { [weak self] result in
                self?.activeWebViews.removeAll { $0 === webView }
                continuation.resume(returning: result)
            }
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            webView.navigationDelegate = delegate

            webView.loadHTMLString(html, baseURL: URL(string: baseURL))
        }
    }

    /// Read current dark mode state (must be called on MainActor before entering nonisolated context).
    private static var isDarkMode: Bool {
        let mode = AppSettings.shared.appearanceMode
        switch mode {
        case .dark: return true
        case .light: return false
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    private static var currentWebRenderStyle: WebRenderStyle {
        let settings = AppSettings.shared
        let rawFontSize = settings.contentFontSize.basePointSize + (settings.readingComfortMode ? 1 : 0)
        let fontSize = settings.effectiveContentPointSize(for: rawFontSize)
        let themeStyle = settings.themeStyle
        return WebRenderStyle(
            bodyFontSize: fontSize,
            quoteFontSize: max(fontSize - 1, 1),
            codeFontSize: max(fontSize - 2, 1),
            accentHex: themeStyle.webAccentHex,
            backgroundHex: themeStyle.webBackgroundHex,
            mutedBackgroundHex: themeStyle.webMutedBackgroundHex,
            quoteBorderHex: themeStyle.webQuoteBorderHex,
            blockquoteBackgroundHex: themeStyle.webBlockquoteBackgroundHex,
            bodyFontFamilyCSS: settings.webContentFontFamilyCSS
        )
    }

    nonisolated private static func buildHTML(
        cooked: String,
        baseURL: String,
        openDetailsIndices: Set<Int> = [],
        isDark: Bool = false,
        webStyle: WebRenderStyle = .default
    ) -> String {
        // Fix lazy-loading images that won't load in off-screen WebView
        let fixedCooked = cooked.replacingOccurrences(of: "loading=\"lazy\"", with: "loading=\"eager\"")

        // Script to open specific <details> elements by index
        let detailsScript: String
        if openDetailsIndices.isEmpty {
            detailsScript = ""
        } else {
            let indices = openDetailsIndices.sorted().map(String.init).joined(separator: ",")
            detailsScript = """
            <script>
            document.querySelectorAll('details').forEach(function(d, i) {
                if ([\(indices)].includes(i)) d.setAttribute('open', '');
            });
            </script>
            """
        }

        let darkLinkHex = "#4db8ff"
        let darkQuoteBorderHex = "#555"
        let darkCSS = """
            body.dark { color: #e0e0e0; background: \(webStyle.backgroundHex); }
            body.dark blockquote { border-left-color: \(darkQuoteBorderHex); color: #aaa; background: \(webStyle.blockquoteBackgroundHex); }
            body.dark aside.quote { border-left-color: \(darkQuoteBorderHex); }
            body.dark aside.quote .title { color: #777; }
            body.dark aside.quote blockquote { color: #aaa; }
            body.dark aside.onebox { border-color: #444; }
            body.dark aside.onebox header.source { background: #2a2a2a; border-bottom-color: #444; }
            body.dark aside.onebox .onebox-body p { color: #aaa; }
            body.dark details { border-color: #444; }
            body.dark details summary { background: #2a2a2a; }
            body.dark pre { background: #2a2a2a; }
            body.dark :not(pre) > code { background: #333; }
            body.dark th, body.dark td { border-color: #555; }
            body.dark a { color: \(darkLinkHex); }
        """

        let bodyClass = isDark ? " class=\"dark\"" : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <base href="\(baseURL)/">
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            padding: 0;
            margin: 0;
            font: -apple-system-body;
            font-size: \(webStyle.bodyFontSize)px;
            font-family: \(webStyle.bodyFontFamilyCSS);
            line-height: 1.45;
            color: #1a1a1a;
            background: \(webStyle.backgroundHex);
            word-wrap: break-word;
            overflow-wrap: break-word;
            -webkit-text-size-adjust: 100%;
        }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        img.emoji {
            display: inline;
            vertical-align: middle;
            width: 20px;
            height: 20px;
            border-radius: 0;
        }
        a { color: \(webStyle.accentHex); text-decoration: none; }
        blockquote {
            border-left: 3px solid \(webStyle.quoteBorderHex);
            margin: 12px 0;
            padding: 0 0 0 16px;
            color: #666;
            background: transparent;
            font-style: italic;
            line-height: 1.5;
            border-radius: 0;
        }

        /* Obsidian-style reference for quoted posts */
        aside.quote {
            border: none;
            border-left: 4px solid \(webStyle.quoteBorderHex);
            border-radius: 8px;
            margin: 16px 0;
            padding: 0 0 0 20px;
            background: \(webStyle.blockquoteBackgroundHex);
            overflow: visible;
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }

        aside.quote .title {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 6px 0 4px;
            background: none;
            font-weight: 600;
            font-size: \(webStyle.quoteFontSize)px;
            color: #888;
            border-bottom: 1px solid \(webStyle.quoteBorderHex);
        }

        aside.quote .title img.avatar {
            width: 20px;
            height: 20px;
            border-radius: 50%;
            border: 1px solid #ddd;
        }

        aside.quote .title .quote-controls { display: none; }
        aside.quote blockquote {
            border-left: none;
            padding: 0;
            margin: 4px 0 0;
            color: #555;
            font-size: \(webStyle.quoteFontSize)px;
            line-height: 1.5;
        }

        aside.quote .title img.avatar {
            width: 20px;
            height: 20px;
            border-radius: 50%;
            border: 1px solid #ddd;
        }

        aside.quote .title .quote-controls { display: none; }
        aside.quote blockquote {
            border-left: none;
            padding: 0;
            margin: 4px 0 0;
            color: #555;
            font-size: \(webStyle.quoteFontSize)px;
            line-height: 1.5;
        }

        /* Onebox / link preview cards */
        aside.onebox {
            border: 1px solid #ddd;
            border-radius: 8px;
            margin: 7px 0;
            overflow: hidden;
        }
        aside.quote .title {
            display: flex;
            align-items: center;
            gap: 6px;
            padding: 4px 0;
            background: none;
            font-weight: 600;
            font-size: 14px;
            color: #888;
        }
        aside.quote .title img.avatar {
            width: 18px;
            height: 18px;
            border-radius: 50%;
        }
        aside.quote .title .quote-controls { display: none; }
        aside.quote blockquote {
            border-left: none;
            padding: 0;
            margin: 0;
            color: #666;
            font-size: \(webStyle.quoteFontSize)px;
        }
        /* Onebox / link preview cards */
        aside.onebox {
            border: 1px solid #ddd;
            border-radius: 8px;
            margin: 7px 0;
            overflow: hidden;
        }
        aside.onebox header.source {
            padding: 6px 10px;
            background: #f8f8f8;
            font-size: 14px;
            border-bottom: 1px solid #ddd;
        }
        aside.onebox header.source a {
            display: flex;
            align-items: center;
            gap: 4px;
        }
        aside.onebox header.source img.site-icon {
            width: 16px;
            height: 16px;
            border-radius: 2px;
        }
        aside.onebox .onebox-body {
            padding: 10px 12px;
        }
        aside.onebox .onebox-body h3 {
            font-size: \(webStyle.quoteFontSize)px;
            margin: 0 0 4px;
        }
        aside.onebox .onebox-body p {
            font-size: \(max(webStyle.bodyFontSize - 2, 1))px;
            color: #666;
            margin: 0;
        }
        aside.onebox .onebox-body .aspect-image,
        aside.onebox .onebox-body .aspect-image-full-size {
            margin: 0 0 6px;
        }
        /* Hashtag — force inline, hide decorative square/icon */
        a.hashtag-cooked {
            display: inline !important;
            margin: 0 !important;
            padding: 0 !important;
        }
        a.hashtag-cooked svg,
        .hashtag-category-square,
        .hashtag-icon {
            display: none !important;
        }
        /* Details / collapsible */
        details {
            border: 1px solid #ddd;
            border-radius: 6px;
            margin: 7px 0;
            overflow: hidden;
        }
        details summary {
            padding: 8px 12px;
            background: #f0f0f0;
            font-weight: 600;
            font-size: \(webStyle.quoteFontSize)px;
            list-style: none;
        }
        details summary::-webkit-details-marker { display: none; }
        details summary::before {
            content: '▶ ';
            font-size: 12px;
        }
        details[open] summary::before {
            content: '▼ ';
        }
        details > *:not(summary) {
            padding: 0 12px;
        }
        details > pre {
            margin: 0;
            border-radius: 0;
        }
        /* Hide Discourse codeblock copy/expand buttons */
        .codeblock-button-wrapper { display: none !important; }
        pre {
            background: #f4f4f4;
            padding: 10px;
            border-radius: 6px;
            overflow-x: hidden;
            margin: 7px 0;
            font-size: \(webStyle.codeFontSize)px;
            white-space: pre;
        }
        code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: \(webStyle.codeFontSize)px;
        }
        :not(pre) > code {
            background: #f0f0f0;
            padding: 2px 5px;
            border-radius: 3px;
        }
        p { margin: 0 0 7px; }
        p:last-child { margin-bottom: 0; }
        h1, h2, h3, h4, h5, h6 { margin: 10px 0 5px; }
        ul, ol { padding-left: 22px; margin: 0 0 7px; }
        li { margin: 0 0 4px; }
        li:last-child { margin-bottom: 0; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 7px 0;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 6px 10px;
            text-align: left;
        }
        .lightbox-wrapper { margin: 4px 0; }
        .lightbox-wrapper a.lightbox { display: block; line-height: 0; }
        .lightbox-wrapper .meta { display: none; }
        .lightbox-wrapper img { cursor: default; }
        \(darkCSS)
        </style>
        </head>
        <body\(bodyClass)>\(fixedCooked)\(detailsScript)</body>
        </html>
        """
    }
}

// MARK: - Render Delegate (height + snapshot + regions)

private final class RenderDelegate: NSObject, WKNavigationDelegate {
    private let completion: (PostContentRenderer.RenderedPost) -> Void
    private var hasCompleted = false

    init(completion: @escaping (PostContentRenderer.RenderedPost) -> Void) {
        self.completion = completion
        super.init()
    }

    private func complete(with result: PostContentRenderer.RenderedPost) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }

    private static let waitAndMeasureJS = """
    await Promise.race([
        Promise.all(Array.from(document.querySelectorAll('img')).map(function(img) {
            if (img.complete) return Promise.resolve();
            return new Promise(function(r) { img.onload = r; img.onerror = r; });
        })),
        new Promise(function(r) { setTimeout(r, 500); })
    ]);
    return document.body.scrollHeight;
    """

    private static let regionExtractionJS = """
    (function() {
        var regions = [];
        document.querySelectorAll('img:not(.emoji):not(.avatar)').forEach(function(img) {
            var rect = img.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            var lightbox = img.closest('a.lightbox');
            regions.push({
                t: 'i',
                u: lightbox ? lightbox.href : img.src,
                x: rect.left, y: rect.top, w: rect.width, h: rect.height
            });
        });
        document.querySelectorAll('a').forEach(function(a) {
            if (a.classList.contains('lightbox')) return;
            // Image-only wraps (GitHub raw/blob around a CDN <img>) are opened
            // via the image region so preview does not fetch the remote href.
            if (a.querySelector('img:not(.emoji):not(.avatar)')) return;
            var rect = a.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            regions.push({
                t: 'l',
                u: a.href,
                x: rect.left, y: rect.top, w: rect.width, h: rect.height
            });
        });
        document.querySelectorAll('details > summary').forEach(function(summary, idx) {
            var rect = summary.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            regions.push({
                t: 'd',
                u: String(idx),
                x: rect.left, y: rect.top, w: rect.width, h: rect.height
            });
        });
        var codeBlocks = [];
        document.querySelectorAll('pre').forEach(function(pre) {
            var rect = pre.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return;
            if (pre.scrollWidth <= rect.width + 1) return;
            var code = pre.querySelector('code');
            codeBlocks.push({
                x: rect.left, y: rect.top, w: rect.width, h: rect.height,
                sw: pre.scrollWidth,
                text: (code || pre).textContent || ''
            });
        });
        return JSON.stringify({regions: regions, codeBlocks: codeBlocks});
    })()
    """

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard !hasCompleted else { return }

            // Step 1: Wait for images to load, then measure height
            webView.callAsyncJavaScript(
                Self.waitAndMeasureJS,
                in: nil,
                in: .page
            ) { [self] result in
                let height: CGFloat
                switch result {
                case .success(let value):
                    height = max(
                        (value as? CGFloat) ?? (value as? Double).map { CGFloat($0) } ?? 100,
                        1
                    )
                case .failure:
                    height = 100
                }

                // Step 2: Resize webView to actual content height (pixel-aligned)
                let scale = UIScreen.main.scale
                let pixelHeight = ceil(height * scale) / scale
                webView.frame.size.height = pixelHeight

                // Step 3: Extract interactive regions and code blocks
                webView.evaluateJavaScript(Self.regionExtractionJS) { [self] regionResult, _ in
                    let (regions, codeBlocks) = Self.parseResult(regionResult)

                    // Step 4: Take snapshot
                    let snapshotConfig = WKSnapshotConfiguration()
                    snapshotConfig.rect = CGRect(origin: .zero, size: webView.bounds.size)
                    webView.takeSnapshot(with: snapshotConfig) { [self] image, _ in
                        // Use the snapshot's actual point height to avoid scaleToFill distortion
                        let finalHeight = image?.size.height ?? pixelHeight
                        self.complete(with: PostContentRenderer.RenderedPost(
                            height: finalHeight,
                            snapshot: image,
                            interactiveRegions: regions,
                            codeBlocks: codeBlocks
                        ))
                    }
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            complete(with: PostContentRenderer.RenderedPost(height: 100, snapshot: nil, interactiveRegions: [], codeBlocks: []))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            complete(with: PostContentRenderer.RenderedPost(height: 100, snapshot: nil, interactiveRegions: [], codeBlocks: []))
        }
    }

    private static func parseResult(_ result: Any?) -> ([InteractiveRegion], [CodeBlockInfo]) {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ([], [])
        }

        let regions: [InteractiveRegion] = (root["regions"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let typeStr = dict["t"] as? String,
                  let urlStr = dict["u"] as? String,
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double,
                  let w = dict["w"] as? Double,
                  let h = dict["h"] as? Double else { return nil }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            switch typeStr {
            case "i":
                guard let url = URL(string: urlStr) else { return nil }
                return InteractiveRegion(kind: .image(url: url), frame: frame)
            case "d":
                guard let idx = Int(urlStr) else { return nil }
                return InteractiveRegion(kind: .details(index: idx), frame: frame)
            default:
                guard let url = URL(string: urlStr) else { return nil }
                return InteractiveRegion(kind: .link(url: url), frame: frame)
            }
        }

        let codeBlocks: [CodeBlockInfo] = (root["codeBlocks"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double,
                  let w = dict["w"] as? Double,
                  let h = dict["h"] as? Double,
                  let sw = dict["sw"] as? Double,
                  let text = dict["text"] as? String else { return nil }
            return CodeBlockInfo(
                frame: CGRect(x: x, y: y, width: w, height: h),
                text: text,
                fullWidth: CGFloat(sw)
            )
        }

        return (regions, codeBlocks)
    }
}
