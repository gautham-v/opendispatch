import Foundation

/// An Instagram account as a source. Instagram has no feed, and a plain request for a profile gets a page with no posts on it, so
/// the profile is opened in a hidden web view (`DiscussionWeb.instagramPostLinks`), which draws the account's latest twelve posts
/// without an account, and each new post is read from the page Instagram gives link-preview crawlers (`PreviewTagPost`). Signing in
/// (`WebAccount.instagram`) is only for when Instagram asks a visitor to. A profile opened as a link reads as the same posts (`page`).
enum InstagramFeed {
    /// The addresses of a profile's posts, as its page links them; nil when no page can run now (an iPhone app in the background).
    typealias PostLinks = @Sendable (_ handle: String) async throws -> [String]?

    static let livePostLinks: PostLinks = { handle in
        #if canImport(WebKit)
        return try await DiscussionWeb.shared.instagramPostLinks(handle)
        #else
        throw DiscussionError.unavailable
        #endif
    }

    static let liveFetch: SocialPosts.Fetch = { url, headers in
        try? await HTTP.fetch(url, timeout: postTimeout, headers: headers)
    }

    static let postTimeout: TimeInterval = 10
    /// Stop reading posts after this; the rest are picked up next refresh.
    static let budget: TimeInterval = 25
    /// Posts read at once for a profile someone is waiting to see.
    static let pageConcurrency = 4

    /// Instagram's own pages, which sit where an account's name would.
    private static let notAccounts: Set<String> = [
        "about", "accounts", "api", "developer", "direct", "explore", "legal", "p", "reel", "reels", "stories", "tv", "web",
    ]
    private static let handlePattern = ExtractionDOM.Pattern(#"^[A-Za-z0-9._]{1,30}$"#)

    /// The account whose profile `url` is; nil for a post or any other address.
    static func handle(ofProfile url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased(), host == "instagram.com" || host == "www.instagram.com" else {
            return nil
        }
        let segments = c.path.split(separator: "/").map(String.init)
        guard segments.count == 1, handlePattern.test(segments[0]), !notAccounts.contains(segments[0].lowercased()) else { return nil }
        return segments[0]
    }

    static func profileURL(_ handle: String) -> String { "https://www.instagram.com/\(handle)/" }

    /// The posts among a page's links, each once at its canonical address, in page order.
    static func postURLs(_ hrefs: [String]) -> [String] {
        var seen = Set<String>()
        return hrefs.compactMap { href in
            let absolute = href.hasPrefix("/") ? "https://www.instagram.com" + href : href
            return PreviewTagPost.canonicalURL(absolute, network: .instagram)
        }.filter { seen.insert($0).inserted }
    }

    /// Instagram's picture and video addresses stop working after days, so what the reader draws from them isn't kept.
    static func isInstagram(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    /// A profile as the reader shows it: its latest posts as cards, newest first.
    static func page(handle: String, links: PostLinks = livePostLinks, fetch: @escaping SocialPosts.Fetch = liveFetch) async throws -> ExtractResult {
        guard let hrefs = try await links(handle) else { throw DiscussionError.unavailable }
        let posts = await withTaskGroup(of: SocialPost?.self) { group -> [SocialPost] in
            var urls = postURLs(hrefs).makeIterator()
            func next() {
                guard let url = urls.next() else { return }
                group.addTask {
                    guard let (data, res) = await fetch(url, SocialPosts.crawlerHeaders), (200..<300).contains(res.statusCode) else { return nil }
                    return PreviewTagPost.parse(html: HTTP.text(data, response: res), canonical: url, network: .instagram)
                }
            }
            for _ in 0..<pageConcurrency { next() }
            var out: [SocialPost] = []
            while let post = await group.next() {
                if let post { out.append(post) }
                next()
            }
            return out
        }
        let cards = posts.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.compactMap { post in
            post.render()?.contentHtml.flatMap { EmbeddedPosts.decorated($0, network: "Instagram", href: post.url) }
        }
        guard !cards.isEmpty else { throw FeedDetectionError("Instagram didn\u{2019}t give this account\u{2019}s posts. Try again in a moment.") }
        return ExtractResult(contentHtml: cards.joined(), leadImage: nil)
    }

    /// The source's new posts. Twelve come at most and few are new, so they're read one at a time. A post that can't be read is tried
    /// again next refresh, except one Instagram says is gone. The grid's order breaks ties among posts of the same day.
    static func read(profile: String, known: Set<String>, links: PostLinks, fetch: SocialPosts.Fetch, now: Date = Date()) async throws -> ScrapeResult {
        guard let handle = handle(ofProfile: profile) else { throw HTTPError.invalidURL(profile) }
        guard let hrefs = try await links(handle) else {
            return ScrapeResult(listingUrl: profile, links: [], items: [], processed: [])
        }
        let urls = postURLs(hrefs)
        let todo = urls.filter { !known.contains($0) }
        let deadline = Date().addingTimeInterval(budget)
        var items: [ParsedItem] = []
        var processed: [String] = []
        for url in todo where Date() < deadline {
            guard let (data, res) = await fetch(url, SocialPosts.crawlerHeaders) else { continue }
            guard (200..<300).contains(res.statusCode) else {
                if res.statusCode < 500, res.statusCode != 429 { processed.append(url) }
                continue
            }
            guard let post = PreviewTagPost.parse(html: HTTP.text(data, response: res), canonical: url, network: .instagram) else { continue }
            var item = post.item(now: now)
            let order = Double(urls.firstIndex(of: url) ?? 0)
            // The tags give a day, whose noon may be later today.
            item.publishedAt = min(item.publishedAt, now).addingTimeInterval(-order)
            items.append(item)
            processed.append(url)
        }
        if !todo.isEmpty, processed.isEmpty {
            throw FeedDetectionError("Instagram didn\u{2019}t give this account\u{2019}s posts. Trying again at the next refresh.")
        }
        return ScrapeResult(listingUrl: profile, links: urls, items: items, processed: processed)
    }
}
