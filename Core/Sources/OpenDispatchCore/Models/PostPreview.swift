import Foundation
import SwiftSoup

/// What a list row needs to show a post at length: its text, first picture or video, quoted post and link card, read from the
/// reader's `.x-post` markup (X, Bluesky, Mastodon, Reddit and the rest) or a feed's HTML. Stored as JSON in `items.post_preview`,
/// so a list query has it without loading `content_html`.
public struct PostPreview: Codable, Sendable, Hashable {
    public struct Quote: Codable, Sendable, Hashable {
        public var name: String
        public var handle: String?
        /// As the markup has it ("Nov 1, 2026").
        public var when: String?
        public var avatar: String?
        public var paragraphs: [String]
        public var links: [String] = []
        public var image: String?
        public var isVideo = false
    }

    public struct Card: Codable, Sendable, Hashable {
        public var domain: String
        /// nil when it would only repeat the domain.
        public var title: String?
        public var image: String?
    }

    /// Plain text, one entry per paragraph; a line break inside one is "\n".
    public var paragraphs: [String] = []
    /// The text of the links in `paragraphs`, so a row can color them.
    public var links: [String] = []
    /// The first photo, or a video's still.
    public var image: String?
    public var isVideo = false
    public var quote: Quote?
    public var card: Card?

    public init(paragraphs: [String] = [], links: [String] = [], image: String? = nil, isVideo: Bool = false, quote: Quote? = nil, card: Card? = nil) {
        self.paragraphs = paragraphs
        self.links = links
        self.image = image
        self.isVideo = isVideo
        self.quote = quote
        self.card = card
    }

    private typealias DOM = ExtractionDOM

    public var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public init?(json: String?) {
        guard let json, let value = try? JSONDecoder().decode(PostPreview.self, from: Data(json.utf8)) else { return nil }
        self = value
    }

    // MARK: Reading

    /// From the reader's post markup; nil for anything else (an article).
    public static func fromMarkup(_ html: String?) -> PostPreview? {
        guard let html, html.contains("x-post") else { return nil }
        let parsed: PostPreview?? = DOM.withFragment(html) { root -> PostPreview? in
            guard let post = DOM.first(root, ".x-post") else { return nil }
            let kids = DOM.children(post)
            func kid(_ name: String) -> Element? { kids.first { DOM.classTokens($0).contains(name) } }
            var out = PostPreview()
            if let body = kid("x-body") {
                out.paragraphs = paragraphs(ofBody: body)
                out.links = linkTexts(body)
            }
            if let media = kid("x-media") { (out.image, out.isVideo) = firstMedia(media) }
            if let el = kid("x-quote") { out.quote = quote(el) }
            if let el = kid("x-card") { out.card = card(el) }
            return out
        }
        return parsed ?? nil
    }

    /// From a feed's entry: the paragraphs of its HTML, or its blank-line-separated lines. `root` limits it to a part of the entry
    /// (Reddit's `.md`, which leaves out the "submitted by" line); nil when there is no such part or no text.
    static func fromFeedHTML(_ html: String?, root query: String? = nil) -> PostPreview? {
        guard let html, !html.isEmpty else { return nil }
        let parsed: PostPreview?? = DOM.withFragment(html) { fragment -> PostPreview? in
            guard let root = query.map({ DOM.first(fragment, $0) }) ?? fragment else { return nil }
            let hasParagraphs = !DOM.select(root, "p").isEmpty
            let paragraphs = (hasParagraphs ? Self.paragraphs(ofBody: root) : DOM.rawText(root).components(separatedBy: "\n\n"))
                .map { $0.replacingOccurrences(of: "[contains quote post or other embedded content]", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return paragraphs.isEmpty ? nil : PostPreview(paragraphs: paragraphs, links: linkTexts(root))
        }
        return parsed ?? nil
    }

    private static func paragraphs(ofBody body: Element) -> [String] {
        DOM.children(body).compactMap { el -> String? in
            let text: String
            if DOM.isTag(el, ["ul", "ol"]) {
                text = DOM.select(el, "li").map { "• " + lines(of: $0) }.joined(separator: "\n")
            } else {
                text = lines(of: el)
            }
            return text.isEmpty ? nil : text
        }
    }

    /// An element's text with its `<br>`s as line breaks and other whitespace collapsed.
    private static func lines(of el: Element) -> String {
        func walk(_ node: Node) -> String {
            if let text = node as? TextNode { return text.getWholeText() }
            if let e = node as? Element, DOM.tag(e) == "br" { return "\u{1F}" }
            return node.getChildNodes().map(walk).joined()
        }
        return tidy(walk(el)).replacingOccurrences(of: " ?\u{1F} ?", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func linkTexts(_ el: Element) -> [String] {
        DOM.select(el, "a").map { DOM.text($0) }.filter { !$0.isEmpty }
    }

    private static func firstMedia(_ el: Element) -> (String?, Bool) {
        guard let first = DOM.first(el, "img, video") else { return (nil, false) }
        let isVideo = DOM.tag(first) == "video"
        return (DOM.attr(first, isVideo ? "poster" : "src"), isVideo)
    }

    private static func quote(_ el: Element) -> Quote? {
        let kids = DOM.children(el)
        guard let who = kids.first(where: { DOM.classTokens($0).contains("x-who") }),
              let name = DOM.first(who, ".x-name").map({ DOM.text($0) }), !name.isEmpty else { return nil }
        let handle = DOM.first(who, ".x-handle").map { DOM.text($0).replacingOccurrences(of: "^@", with: "", options: .regularExpression) }
        let when = DOM.first(who, ".x-when").map { DOM.text($0).replacingOccurrences(of: #"^·\s*"#, with: "", options: .regularExpression) }
        let body = kids.first { DOM.classTokens($0).contains("x-body") }
        let media = kids.first { DOM.classTokens($0).contains("x-media") }.map(firstMedia) ?? (nil, false)
        return Quote(name: name, handle: handle, when: when, avatar: DOM.first(who, ".x-avatar").flatMap { DOM.attr($0, "src") },
                     paragraphs: body.map(paragraphs(ofBody:)) ?? [], links: body.map(linkTexts) ?? [], image: media.0, isVideo: media.1)
    }

    private static func card(_ el: Element) -> Card? {
        guard let domain = DOM.first(el, ".x-card-domain").map({ DOM.text($0) }), !domain.isEmpty else { return nil }
        let title = DOM.first(el, ".x-card-title").map { DOM.text($0) }
        return Card(domain: domain, title: title == domain || title?.isEmpty == true ? nil : title,
                    image: DOM.first(el, ".x-card-img").flatMap { DOM.attr($0, "src") })
    }
}

extension Item {
    /// The post as a list row shows it at length: what was stored, or for a post stored without it, what the row always knew
    /// (its first paragraph, clipped; the first line of a quoted post; the thumbnail).
    public var listPost: PostPreview {
        var post = PostPreview(json: postPreviewJSON) ?? PostPreview()
        let isReddit = DiscussionPlace.thread(of: url) == .reddit
        if isReddit {
            // The reader's Reddit markup starts with the title, which the row draws as its heading.
            if let first = post.paragraphs.first, Self.sameText(first, title) { post.paragraphs.removeFirst() }
            if postPreviewJSON == nil, let body = Self.redditBody(summary) { post.paragraphs = [body] }
        } else if post.paragraphs.isEmpty, postPreviewJSON == nil {
            post.paragraphs = [title]
        }
        if post.image == nil, !isReddit, let thumb = thumbnailUrl, !thumb.isEmpty {
            post.image = thumb.replacingOccurrences(of: "name=small", with: "name=medium")
            post.isVideo = thumb.contains("video_thumb")
        }
        if post.quote == nil, let quote = Self.summaryQuote(summary, avatar: quoteAvatarUrl) { post.quote = quote }
        return post
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return norm(a) == norm(b)
    }

    /// A Reddit feed's summary without the line it ends with; nil when that was all of it.
    private static func redditBody(_ summary: String?) -> String? {
        let text = TextFormat.stripHTML(summary)
            .replacingOccurrences(of: #"\s*submitted by\s.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// "Quoting Name: text", the summary the scraper writes for a quote post.
    private static func summaryQuote(_ summary: String?, avatar: String?) -> PostPreview.Quote? {
        let text = TextFormat.stripHTML(summary)
        guard text.hasPrefix("Quoting "), let colon = text.range(of: ": ") else { return nil }
        let name = String(text[text.index(text.startIndex, offsetBy: 8)..<colon.lowerBound])
        let line = String(text[colon.upperBound...])
            .replacingOccurrences(of: #"\s*https?://t\.co/\S*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return PostPreview.Quote(name: name, avatar: avatar, paragraphs: line.isEmpty ? [] : [line])
    }
}

/// Where a long post's text stops in a list row, given how many lines each paragraph takes.
public enum PostCut {
    public struct Plan: Equatable, Sendable {
        /// How many paragraphs show.
        public var visible: Int
        /// The last visible paragraph's line limit; nil when it shows whole.
        public var lastLineLimit: Int?
        public var isCut: Bool

        public init(visible: Int, lastLineLimit: Int?, isCut: Bool) {
            self.visible = visible
            self.lastLineLimit = lastLineLimit
            self.isCut = isCut
        }
    }

    /// Up to `cap` lines. With `clean`, a cut that would leave only one line of the next paragraph stops at the paragraph
    /// before it instead, so no stray words sit above Show more.
    public static func plan(lineCounts: [Int], cap: Int, clean: Bool) -> Plan {
        var used = 0
        for (index, lines) in lineCounts.enumerated() {
            if used + lines <= cap {
                used += lines
                continue
            }
            let left = cap - used
            if left >= (clean ? 2 : 1) { return Plan(visible: index + 1, lastLineLimit: left, isCut: true) }
            return Plan(visible: index, lastLineLimit: nil, isCut: true)
        }
        return Plan(visible: lineCounts.count, lastLineLimit: nil, isCut: false)
    }
}
