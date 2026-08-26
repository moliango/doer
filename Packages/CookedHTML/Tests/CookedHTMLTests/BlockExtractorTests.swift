import XCTest
@testable import CookedHTML

final class BlockExtractorTests: XCTestCase {

    // MARK: - Paragraph

    func testSimpleParagraph() {
        let html = "<p>Hello world</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph(let inlines) = blocks[0] {
            XCTAssertEqual(inlines, [.text("Hello world")])
        } else {
            XCTFail("Expected paragraph, got \(blocks[0])")
        }
    }

    func testMultipleParagraphs() {
        let html = "<p>First</p><p>Second</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 2)
    }

    // MARK: - Headings

    func testHeadings() {
        let html = "<h1>Title</h1><h2>Subtitle</h2><h3>Section</h3>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 3)

        if case .heading(let level, let content) = blocks[0] {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(content, [.text("Title")])
        } else {
            XCTFail("Expected h1")
        }

        if case .heading(let level, _) = blocks[1] {
            XCTAssertEqual(level, 2)
        } else {
            XCTFail("Expected h2")
        }
    }

    // MARK: - Code Block

    func testCodeBlock() {
        let html = """
        <pre><code class="lang-swift">let x = 42</code></pre>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 42")
        } else {
            XCTFail("Expected codeBlock, got \(blocks[0])")
        }
    }

    func testCodeBlockNoLanguage() {
        let html = "<pre><code>plain code</code></pre>"
        let blocks = CookedHTMLParser.parse(html: html)
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertNil(lang)
            XCTAssertEqual(code, "plain code")
        } else {
            XCTFail("Expected codeBlock")
        }
    }

    func testMermaidDivExtractsAsCodeBlock() {
        let html = """
        <div class="mermaid" id="flowchart-linux-do">
        flowchart TD
            User[用户] --> CF[Cloudflare<br>CDN]
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "mermaid")
            XCTAssertTrue(code.contains("flowchart TD"))
            XCTAssertTrue(code.contains("Cloudflare"))
        } else {
            XCTFail("Expected mermaid codeBlock")
        }
    }

    func testHighlightedJSLineNumberTablePreservesNewlines() {
        let html = """
        <div class="highlighted">
        <pre><code class="hljs language-swift">
        <table class="hljs-ln"><tbody>
        <tr><td class="hljs-ln-numbers"><div class="hljs-ln-n" data-line-number="1"></div></td>
        <td class="hljs-ln-code"><div class="hljs-ln-line"><span class="hljs-keyword">let</span> x = 1</div></td></tr>
        <tr><td class="hljs-ln-numbers"><div class="hljs-ln-n" data-line-number="2"></div></td>
        <td class="hljs-ln-code"><div class="hljs-ln-line"><span class="hljs-keyword">let</span> y = 2</div></td></tr>
        </tbody></table>
        </code></pre>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1, "Expected one code block, got \(blocks)")
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1\nlet y = 2")
        } else {
            XCTFail("Expected codeBlock, got \(blocks[0])")
        }
    }

    func testParagraphWrappedPreExtractsAsCodeBlock() {
        let html = "<p><pre><code class=\"lang-bash\">echo hi</code></pre></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1, "Expected one code block, got \(blocks)")
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "bash")
            XCTAssertEqual(code, "echo hi")
        } else {
            XCTFail("Expected codeBlock, got \(blocks[0])")
        }
    }

    func testMermaidWrapAttributeExtractsAsCodeBlock() {
        let html = """
        <div class="d-wrap" data-code-wrap="mermaid">
        <pre><code class="lang-mermaid">flowchart TD
            A --> B</code></pre>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1, "Expected one mermaid block, got \(blocks)")
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "mermaid")
            XCTAssertTrue(code.contains("flowchart TD"))
            XCTAssertTrue(code.contains("A --> B"))
        } else {
            XCTFail("Expected mermaid codeBlock, got \(blocks[0])")
        }
    }

    func testGitHubGistOneboxLiftsNestedCodeBlock() {
        let html = """
        <aside class="onebox githubgist">
          <header class="source"><a href="https://gist.github.com/user/abc">gist.github.com</a></header>
          <article class="onebox-body">
            <h4><a href="https://gist.github.com/user/abc">file.swift</a></h4>
            <pre><code class="lang-swift">func hello() {\n  print("hi")\n}</code></pre>
          </article>
        </aside>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 2, "Expected onebox + code, got \(blocks)")
        if case .onebox(let sourceURL, _, _, _, _, _, _) = blocks[0] {
            XCTAssertEqual(sourceURL, "https://gist.github.com/user/abc")
        } else {
            XCTFail("Expected onebox, got \(blocks[0])")
        }
        if case .codeBlock(let lang, let code) = blocks[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "func hello() {\n  print(\"hi\")\n}")
        } else {
            XCTFail("Expected nested codeBlock, got \(blocks[1])")
        }
    }

    // MARK: - Blockquote

    func testBlockquote() {
        let html = "<blockquote><p>Quoted text</p></blockquote>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .blockquote(let inner) = blocks[0] {
            XCTAssertEqual(inner.count, 1)
            if case .paragraph(let inlines) = inner[0] {
                XCTAssertEqual(inlines, [.text("Quoted text")])
            }
        } else {
            XCTFail("Expected blockquote")
        }
    }

    // MARK: - Divider

    func testHorizontalRule() {
        let html = "<p>Before</p><hr><p>After</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .divider)
    }

    // MARK: - Image

    func testStandaloneImage() {
        let html = "<p><img src=\"/uploads/test.png\" alt=\"test\" width=\"100\" height=\"50\"></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, let alt, let w, let h, _) = blocks[0] {
            XCTAssertEqual(src, "/uploads/test.png")
            XCTAssertEqual(alt, "test")
            XCTAssertEqual(w, 100)
            XCTAssertEqual(h, 50)
        } else {
            XCTFail("Expected image, got \(blocks[0])")
        }
    }

    func testImageWithBaseURL() {
        let html = "<p><img src=\"/uploads/test.png\"></p>"
        let blocks = CookedHTMLParser.parse(html: html, baseURL: "https://linux.do")
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, "https://linux.do/uploads/test.png")
        } else {
            XCTFail("Expected image")
        }
    }

    func testImageGridCarousel() {
        let html = """
        <div class="d-image-grid d-image-grid--carousel" data-mode="carousel">
        <div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/c1.jpg"><img src="https://example.com/c1_thumb.jpg" alt="片 1" width="800" height="450"></a></div>
        <div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/c2.jpg"><img src="https://example.com/c2_thumb.jpg" alt="片 2" width="800" height="450"></a></div>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        guard case let .imageGrid(images, _, mode) = blocks[0] else {
            return XCTFail("Expected imageGrid, got \(blocks[0])")
        }
        XCTAssertEqual(mode, .carousel)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].src, "https://example.com/c1_thumb.jpg")
        XCTAssertEqual(images[0].href, "https://example.com/c1.jpg")
        XCTAssertEqual(images[0].alt, "片 1")
    }

    func testBareAutoLinkedImageURLPromotesToImageBlock() {
        let url = "https://pan.644222.xyz/raw/C5F1D31007AC3AB3B1134F88C12E1F0.jpg"
        let html = "<p><a href=\"\(url)\">\(url)</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, let alt, _, _, let href) = blocks[0] {
            XCTAssertEqual(src, url)
            XCTAssertNil(alt)
            XCTAssertEqual(href, url)
        } else {
            XCTFail("Expected image block, got \(blocks[0])")
        }
    }

    func testBareBadgeURLWithoutExtensionPromotesToImageBlock() {
        let url = "https://prompt.iwooji.com/badge?u=alieismy&t=linux-do"
        let html = "<p><a href=\"\(url)\">\(url)</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, let href) = blocks[0] {
            XCTAssertEqual(src, url)
            XCTAssertEqual(href, url)
        } else {
            XCTFail("Expected image block for badge URL, got \(blocks[0])")
        }
    }

    func testSoleParagraphImageLinkPromotesEvenWithCustomLabel() {
        // FluxDo-style: a paragraph that is only an image link becomes an image block.
        let html = "<p><a href=\"https://example.com/photo.jpg\">click here</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, "https://example.com/photo.jpg")
        } else {
            XCTFail("Expected image block, got \(blocks[0])")
        }
    }

    func testInlineImageLinkWithCustomLabelIsNotPromoted() {
        let html = "<p>see <a href=\"https://example.com/photo.jpg\">click here</a> please</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph(let inlines) = blocks[0] {
            XCTAssertTrue(inlines.contains { if case .link = $0 { return true }; return false })
        } else {
            XCTFail("Expected paragraph, got \(blocks[0])")
        }
    }

    func testHeaderlessOneboxAsideWithImageURLTitlePromotesToImageBlock() {
        let url = "https://pan.644222.xyz/raw/C5F1D31007AC3AB3B1134F88C12E1F0.jpg"
        let html = """
        <aside class="onebox allowlistedgeneric"><article class="onebox-body">\
        <h3><a href="\(url)" target="_blank" rel="noopener nofollow ugc">\(url)</a></h3>\
        </article></aside>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, url)
        } else {
            XCTFail("Expected image block from headerless onebox, got \(blocks[0])")
        }
    }

    func testHeaderlessOneboxAsideWithBadgeURLPromotesToImageBlock() {
        let url = "https://prompt.iwooji.com/badge?u=alieismy&t=linux-do&tc=%236966ea"
        let html = """
        <aside class="onebox"><article class="onebox-body">\
        <h3><a href="\(url.replacingOccurrences(of: "&", with: "&amp;"))">\(url)</a></h3>\
        </article></aside>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, url)
        } else {
            XCTFail("Expected image block from badge onebox, got \(blocks[0])")
        }
    }

    func testRichOneboxWithRealTitleStaysOnebox() {
        let html = """
        <aside class="onebox githubrepo"><header class="source"><a href="https://github.com/foo/bar">github.com</a></header>\
        <article class="onebox-body"><img src="https://opengraph.githubassets.com/x/foo/bar.png" class="thumbnail">\
        <h3><a href="https://github.com/foo/bar">GitHub - foo/bar</a></h3>\
        <p>A sample repository description.</p></article></aside>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .onebox = blocks[0] {
        } else {
            XCTFail("Expected onebox to stay onebox, got \(blocks[0])")
        }
    }

    func testBareImageURLAfterTextSplitsParagraph() {
        let url = "https://cdn.example.com/a.png"
        let html = "<p>see this<br><a href=\"\(url)\">\(url)</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 2, "Expected text + image, got \(blocks)")
        if case .paragraph(let inlines) = blocks[0] {
            XCTAssertEqual(inlines, [.text("see this")])
        } else {
            XCTFail("Expected leading paragraph, got \(blocks[0])")
        }
        if case .image(let src, _, _, _, _) = blocks[1] {
            XCTAssertEqual(src, url)
        } else {
            XCTFail("Expected trailing image, got \(blocks[1])")
        }
    }

    func testPlainTextImageURLPromotesToImageBlock() {
        let url = "https://cdn.example.com/plain.webp"
        let html = "<p>\(url)</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, url)
        } else {
            XCTFail("Expected image from plain text URL, got \(blocks[0])")
        }
    }


    func testSoleImageLinkPromotesEvenWhenLabelDiffers() {
        let href = "https://cdn.example.com/shot.jpeg"
        let html = "<p><a href=\"\(href)\">cdn.example.com</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, href)
        } else {
            XCTFail("Expected image from sole link with domain label, got \(blocks[0])")
        }
    }

    func testTruncatedAutoLinkLabelStillPromotes() {
        let href = "https://prompt.iwooji.com/badge?u=alieismy&t=linux-do&w=hello&ec=717c6028"
        let label = String(href.prefix(40)) + "..."
        let html = "<p><a href=\"\(href)\">\(label)</a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, href)
        } else {
            XCTFail("Expected image from truncated label link, got \(blocks[0])")
        }
    }

    func testMultilinePlainTextImageURLPromotes() {
        let url = "https://cdn.example.com/path/to/photo.png"
        let html = "<p>https://cdn.example.com/path/<br>to/photo.png</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let src, _, _, _, _) = blocks[0] {
            XCTAssertEqual(src, url)
        } else {
            XCTFail("Expected image from multiline plain URL, got \(blocks[0])")
        }
    }

    // MARK: - Details

    func testDetails() {
        let html = """
        <details>
            <summary>Click me</summary>
            <p>Hidden content</p>
        </details>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .details(let summary, let content) = blocks[0] {
            XCTAssertEqual(summary, [.text("Click me")])
            XCTAssertEqual(content.count, 1)
        } else {
            XCTFail("Expected details, got \(blocks[0])")
        }
    }

    // MARK: - Empty/Whitespace

    func testEmptyParagraphsAreSkipped() {
        let html = "<p>   </p><p>Real content</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
    }

    func testLineBreakOnlyParagraphsAreSkipped() {
        let html = "<p>Before</p><p><br></p><p><br><br></p><p>After</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .paragraph([.text("Before")]))
        XCTAssertEqual(blocks[1], .paragraph([.text("After")]))
    }

    func testConsecutiveLineBreaksAreCollapsedInsideParagraph() {
        let html = "<p>First<br><br><br>Second</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else {
            XCTFail("Expected paragraph, got \(blocks[0])")
            return
        }
        XCTAssertEqual(inlines, [.text("First"), .lineBreak, .text("Second")])
    }

    // MARK: - Spoiler

    func testBlockSpoiler() {
        let html = """
        <div class="spoiler">
        <p>此文本将被模糊处理</p>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .spoiler(let inner) = blocks[0] {
            XCTAssertEqual(inner.count, 1)
            if case .paragraph(let inlines) = inner[0] {
                XCTAssertEqual(inlines, [.text("此文本将被模糊处理")])
            } else {
                XCTFail("Expected paragraph inside spoiler, got \(inner[0])")
            }
        } else {
            XCTFail("Expected .spoiler block, got \(blocks[0])")
        }
    }

    func testBlockSpoilerWithMultipleChildren() {
        let html = """
        <div class="spoiler">
        <p>First hidden paragraph</p>
        <p>Second hidden paragraph</p>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .spoiler(let inner) = blocks[0] {
            XCTAssertEqual(inner.count, 2)
            for block in inner {
                if case .paragraph = block {
                    // OK
                } else {
                    XCTFail("Expected paragraph, got \(block)")
                }
            }
        } else {
            XCTFail("Expected .spoiler block, got \(blocks[0])")
        }
    }

    func testBlockSpoilerWithList() {
        let html = """
        <div class="spoiler">
        <ol>
        <li>First item</li>
        <li>Second item</li>
        </ol>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .spoiler(let inner) = blocks[0] {
            XCTAssertEqual(inner.count, 1)
            if case .list(let ordered, _, let items) = inner[0] {
                XCTAssertTrue(ordered)
                XCTAssertEqual(items.count, 2)
            } else {
                XCTFail("Expected list inside spoiler, got \(inner[0])")
            }
        } else {
            XCTFail("Expected .spoiler block, got \(blocks[0])")
        }
    }

    // MARK: - Poll

    func testDiscoursePollDoesNotBecomeList() {
        let html = """
        <div class="poll" data-poll-name="poll" data-poll-type="regular" data-poll-status="open">
          <div class="poll-container">
            <ul>
              <li data-poll-option-id="18-23"><p>18-23</p></li>
              <li data-poll-option-id="24-29"><p>24-29</p></li>
              <li data-poll-option-id="30-35"><p>30-35</p></li>
              <li data-poll-option-id="35+"><p>35+</p></li>
            </ul>
          </div>
          <div class="poll-info">
            <span class="info-number">0</span>
            <span class="info-label">投票人</span>
          </div>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .poll(let poll) = blocks[0] {
            XCTAssertEqual(poll.name, "poll")
            XCTAssertEqual(poll.options.map(\.text), ["18-23", "24-29", "30-35", "35+"])
            XCTAssertEqual(poll.votersText, "0 投票人")
            XCTAssertEqual(poll.status, "open")
        } else {
            XCTFail("Expected poll block, got \(blocks)")
        }
    }

    func testDiscoursePollParsesVoteMetadata() {
        let html = """
        <div class="poll" data-poll-name="poll" data-poll-type="regular" data-poll-status="open" data-poll-public="true" data-poll-results="always" data-poll-min="1" data-poll-max="1">
          <div class="poll-container">
            <ul>
              <li class="chosen" data-poll-option-id="alpha" data-poll-option-votes="8">
                <p>Alpha</p>
                <span class="percentage">80%</span>
              </li>
              <li data-poll-option-id="beta" data-poll-option-votes="2">
                <p>Beta</p>
                <span class="percentage">20%</span>
              </li>
            </ul>
          </div>
          <div class="poll-info">
            <span class="info-number">10</span>
            <span class="info-label">投票人</span>
          </div>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        if case .poll(let poll) = blocks[0] {
            XCTAssertEqual(poll.name, "poll")
            XCTAssertEqual(poll.votersText, "10 投票人")
            XCTAssertEqual(poll.votersCount, 10)
            XCTAssertEqual(poll.minSelections, 1)
            XCTAssertEqual(poll.maxSelections, 1)
            XCTAssertEqual(poll.resultsMode, "always")
            XCTAssertTrue(poll.isPublic)
            XCTAssertEqual(poll.options[0].id, "alpha")
            XCTAssertEqual(poll.options[0].voteCount, 8)
            XCTAssertEqual(poll.options[0].percentageText, "80%")
            XCTAssertTrue(poll.options[0].isSelected)
            XCTAssertEqual(poll.options[1].id, "beta")
            XCTAssertEqual(poll.options[1].voteCount, 2)
            XCTAssertEqual(poll.options[1].percentageText, "20%")
            XCTAssertFalse(poll.options[1].isSelected)
        } else {
            XCTFail("Expected poll block, got \(blocks)")
        }
    }

    // MARK: - Lightbox + inline text

    func testLightboxFollowedByTextAndEmoji() {
        let html = "<p><div class=\"lightbox-wrapper\"><a class=\"lightbox\" href=\"https://cdn3.linux.do/original/img.jpeg\"><img src=\"https://cdn3.linux.do/optimized/img_245x500.jpeg\" alt=\"Screenshot\" width=\"245\" height=\"500\"><div class=\"meta\"></div></a></div><br>\n点开看到它了，这下真是全民<img src=\"https://cdn.linux.do/images/emoji/twemoji/lobster.png?v=15\" class=\"emoji\" alt=\"lobster\" width=\"20\" height=\"20\">了，微信那么庞大用户</p>"
        let blocks = CookedHTMLParser.parse(html: html)
        for (i, b) in blocks.enumerated() { print("Block \(i): \(b)") }
        // Should be: image block + single paragraph (text + emoji + text)
        XCTAssertEqual(blocks.count, 2, "Expected image + paragraph, got \(blocks.count) blocks: \(blocks)")
        if case .paragraph(let inlines) = blocks[1] {
            // Last inline should be the text after emoji
            if case .text(let t) = inlines.last {
                XCTAssertEqual(t, "了，微信那么庞大用户")
            } else {
                XCTFail("Last inline should be trailing text, got \(inlines)")
            }
        } else {
            XCTFail("Block 1 should be paragraph, got \(blocks[1])")
        }
    }

    func testImageSourceURLsCollectsNestedContentImages() {
        let html = """
        <p>inline <img src="/emoji.png" width="20" height="20"></p>
        <blockquote><p><img src="/quote.png"></p></blockquote>
        <details><summary>more</summary><p><img src="/details.png"></p></details>
        <aside class="onebox">
            <header class="source"><a href="https://example.com">example.com</a></header>
            <article class="onebox-body">
                <img src="/onebox.png">
                <h3><a href="https://example.com">Example</a></h3>
            </article>
        </aside>
        """
        let blocks = CookedHTMLParser.parse(html: html, baseURL: "https://linux.do")

        XCTAssertEqual(blocks.flatMap(\.imageSourceURLs), [
            "https://linux.do/emoji.png",
            "https://linux.do/quote.png",
            "https://linux.do/details.png",
            "https://linux.do/onebox.png",
        ])
    }

    // MARK: - List item lightbox (FluxDo parity)

    /// Discourse `[details]` screenshot galleries put lightbox wrappers inside `<li>`.
    /// Those must become real `.image` children — not dropped text-only list items.
    func testDetailsListWithLightboxImagesBecomeListItemChildren() {
        let html = """
        <details>
          <summary>截图</summary>
          <ul>
            <li>
              <p>PC端</p>
              <div class="lightbox-wrapper">
                <a class="lightbox" href="https://cdn.example.com/original/pc.png">
                  <img src="https://cdn.example.com/optimized/pc_690x400.png" alt="pc" width="690" height="400">
                  <div class="meta">PC</div>
                </a>
              </div>
            </li>
            <li>
              <p>移动端</p>
              <div class="lightbox-wrapper">
                <a class="lightbox" href="https://cdn.example.com/original/mobile.png">
                  <img src="https://cdn.example.com/optimized/mobile_300x600.png" alt="mobile" width="300" height="600">
                </a>
              </div>
            </li>
          </ul>
        </details>
        """
        let blocks = CookedHTMLParser.parse(html: html, baseURL: "https://linux.do")
        XCTAssertEqual(blocks.count, 1)
        guard case .details(let summary, let content) = blocks[0] else {
            XCTFail("Expected details, got \(blocks[0])")
            return
        }
        XCTAssertEqual(summary, [.text("截图")])
        XCTAssertEqual(content.count, 1)
        guard case .list(let ordered, _, let items) = content[0] else {
            XCTFail("Expected list inside details, got \(content[0])")
            return
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 2)

        // Item labels stay as text content.
        XCTAssertEqual(items[0].content, [.text("PC端")])
        XCTAssertEqual(items[1].content, [.text("移动端")])

        // Screenshots must be block children with resolved src + original href.
        XCTAssertEqual(items[0].children.count, 1, "PC item should have image child, got \(items[0].children)")
        XCTAssertEqual(items[1].children.count, 1, "Mobile item should have image child, got \(items[1].children)")

        guard case .image(let pcSrc, _, let pcW, let pcH, let pcHref) = items[0].children[0] else {
            XCTFail("Expected image child for PC, got \(items[0].children[0])")
            return
        }
        XCTAssertTrue(pcSrc.contains("pc_690x400") || pcSrc.contains("pc.png"), "src=\(pcSrc)")
        XCTAssertEqual(pcW, 690)
        XCTAssertEqual(pcH, 400)
        XCTAssertEqual(pcHref, "https://cdn.example.com/original/pc.png")

        guard case .image(let mobileSrc, _, _, _, let mobileHref) = items[1].children[0] else {
            XCTFail("Expected image child for mobile, got \(items[1].children[0])")
            return
        }
        XCTAssertTrue(mobileSrc.contains("mobile"), "src=\(mobileSrc)")
        XCTAssertEqual(mobileHref, "https://cdn.example.com/original/mobile.png")

        // Nested image URLs must surface for gallery / preload collection.
        let urls = blocks.flatMap(\.imageSourceURLs)
        XCTAssertTrue(urls.contains { $0.contains("pc_") || $0.contains("pc.png") })
        XCTAssertTrue(urls.contains { $0.contains("mobile") })
    }

    func testListItemBareImgBecomesChildImageBlock() {
        let html = """
        <ul>
          <li>Shot<br><img src="/uploads/a.png" width="400" height="300"></li>
        </ul>
        """
        let blocks = CookedHTMLParser.parse(html: html, baseURL: "https://linux.do")
        guard case .list(_, _, let items) = blocks[0] else {
            XCTFail("Expected list, got \(blocks[0])")
            return
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].children.isEmpty, "Bare img inside li must become a child block")
        guard case .image(let src, _, let w, let h, _) = items[0].children[0] else {
            XCTFail("Expected image child, got \(items[0].children)")
            return
        }
        XCTAssertEqual(src, "https://linux.do/uploads/a.png")
        XCTAssertEqual(w, 400)
        XCTAssertEqual(h, 300)
    }

    /// Discourse splits product lists interrupted by `[details]` into many single-item
    /// `<ol>` fragments. FluxDo continues 1, 2, 3… — we must too.
    func testOrderedListsContinueNumberingAcrossDetails() {
        let html = """
        <ol><li><p>EZVenera</p></li></ol>
        <details><summary>截图</summary><p>shot</p></details>
        <ol><li><p>TTTTV</p></li></ol>
        <details><summary>截图</summary><p>shot</p></details>
        <ol><li><p>BiliTune</p></li></ol>
        <details><summary>截图</summary><p>shot</p></details>
        <ol><li><p>JavBus</p></li></ol>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        var starts: [Int] = []
        for block in blocks {
            if case .list(let ordered, let start, let items) = block, ordered {
                XCTAssertEqual(items.count, 1)
                starts.append(start)
            }
        }
        XCTAssertEqual(starts, [1, 2, 3, 4], "Continued numbering across details, got \(starts)")
    }

    func testOrderedListRespectsExplicitStartAttribute() {
        let html = """
        <ol start="5"><li>Fifth</li><li>Sixth</li></ol>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        guard case .list(let ordered, let start, let items) = blocks[0] else {
            XCTFail("Expected ordered list, got \(blocks[0])")
            return
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(start, 5)
        XCTAssertEqual(items.count, 2)
    }

    func testOrderedListRestartsAfterParagraph() {
        let html = """
        <ol><li>A</li></ol>
        <p>note between lists</p>
        <ol><li>B</li></ol>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        var starts: [Int] = []
        for block in blocks {
            if case .list(let ordered, let start, _) = block, ordered {
                starts.append(start)
            }
        }
        XCTAssertEqual(starts, [1, 1], "Paragraph should break continued numbering, got \(starts)")
    }

    func testGitHubBlobWrappedImageKeepsCDNSource() {
        let src = "https://cdn3.ldstatic.com/original/4X/9/4/3/943aa351d5a76ad949f237fb776e0250611ebcb9.jpeg"
        let href = "https://github.com/czm15053/linuxdo-idea-ui/blob/main/snapshot/detail.png"
        let html = "<p><a href=\"\(href)\"><img src=\"\(src)\" alt=\"帖子详情\" width=\"690\" height=\"423\"></a></p>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        guard case .image(let parsedSrc, let alt, let width, let height, let parsedHref) = blocks[0] else {
            return XCTFail("Expected image block, got \(blocks[0])")
        }
        XCTAssertEqual(parsedSrc, src)
        XCTAssertEqual(alt, "帖子详情")
        XCTAssertEqual(width, 690)
        XCTAssertEqual(height, 423)
        XCTAssertEqual(parsedHref, href)
    }

    func testMdTableGitHubBlobWrappedImagesKeepCDNSource() {
        let src = "https://cdn3.ldstatic.com/original/4X/9/4/3/943aa351d5a76ad949f237fb776e0250611ebcb9.jpeg"
        let href = "https://github.com/czm15053/linuxdo-idea-ui/blob/main/snapshot/%E5%B8%96%E5%AD%90%E8%AF%A6%E6%83%85.png"
        let html = """
        <div class="md-table">
        <table>
        <thead><tr><th></th><th></th></tr></thead>
        <tbody>
        <tr>
        <td>帖子详情</td>
        <td><a href="\(href)"><img src="\(src)" alt="帖子详情" width="690" height="423"></a></td>
        </tr>
        </tbody>
        </table>
        </div>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(_, let rows) = blocks[0] else {
            return XCTFail("Expected table, got \(blocks[0])")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 2)
        guard case .image(let parsedSrc, _, let width, let height, let parsedHref) = rows[0][1].first else {
            return XCTFail("Expected image in table cell, got \(rows[0][1])")
        }
        XCTAssertEqual(parsedSrc, src)
        XCTAssertEqual(width, 690)
        XCTAssertEqual(height, 423)
        XCTAssertEqual(parsedHref, href)
    }
}
