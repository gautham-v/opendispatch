import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if os(iOS)
import UIKit
#endif
import os

/// The sites a signed-in session counts for. The app's web views share one persistent data store
/// (`WKWebsiteDataStore.default()`), so signing in on the sign-in sheet signs the hidden views in too.
public enum WebAccount: String, Sendable, CaseIterable, Identifiable {
    case x, reddit, instagram, youtube

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .x: "X"
        case .reddit: "Reddit"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        }
    }

    /// Where the sign-in sheet starts.
    public var signInURL: URL {
        switch self {
        case .x: URL(string: "https://x.com/i/flow/login")!
        case .reddit: URL(string: "https://www.reddit.com/login/")!
        case .instagram: URL(string: "https://www.instagram.com/accounts/login/")!
        // The page needs a sign-in, so it goes to Google's and comes back with YouTube's session.
        case .youtube: URL(string: "https://www.youtube.com/feed/channels")!
        }
    }

    /// The cookie a signed-in session has, and the domains it lives on.
    var sessionCookie: String {
        switch self {
        case .x: "auth_token"
        case .reddit: "reddit_session"
        case .instagram: "sessionid"
        case .youtube: "LOGIN_INFO"
        }
    }

    var domains: [String] {
        switch self {
        case .x: ["x.com", "twitter.com"]
        case .reddit: ["reddit.com"]
        case .instagram: ["instagram.com"]
        case .youtube: ["youtube.com"]
        }
    }

    /// What signing out clears beyond `domains`: a YouTube session comes from a Google one, which would sign it straight back in.
    var signOutDomains: [String] {
        self == .youtube ? domains + ["google.com"] : domains
    }

    /// The user agent the sign-in sheet and the hidden view present: Safari's, which X expects of a browser it lets sign in.
    public static var browserUserAgent: String {
        #if os(iOS)
        mobileUserAgent
        #else
        desktopUserAgent
        #endif
    }

    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    /// YouTube's desktop site, which lists subscriptions the same on every device.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
}


#if canImport(WebKit)
extension WebAccount {
    /// The data store every OpenDispatch web view that should share a sign-in uses.
    @MainActor public static var dataStore: WKWebsiteDataStore { .default() }

    @MainActor private static var storeLoaded = false

    /// The data store's cookies. Until the store is loaded from disk its cookie store reads as empty (at launch, before any
    /// web view), so the first call asks for its records, which loads it.
    @MainActor static func cookies() async -> [HTTPCookie] {
        if !storeLoaded {
            _ = await dataStore.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
            storeLoaded = true
        }
        return await dataStore.httpCookieStore.allCookies()
    }

    /// A session cookie for the site is in the app's data store.
    @MainActor public func isSignedIn() async -> Bool {
        let cookies = await Self.cookies()
        return cookies.contains { cookie in
            cookie.name == sessionCookie && !cookie.value.isEmpty && domains.contains { cookie.domain.hasSuffix($0) }
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    /// Removes everything the site stored (cookies, storage), which signs the app out of it.
    @MainActor public func signOut() async {
        let store = Self.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { r in signOutDomains.contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: types, for: mine)
        DiscussionWeb.shared.forget(self)
    }
}

/// Hidden web views that read Reddit and X the way a browser does, for the sites that refuse everything else.
///
/// Reddit: one view sits on reddit.com. Reddit answers a new visitor with a JavaScript challenge, which the view passes
/// by loading a page; after that, pages are fetched from inside it (`fetch` in an isolated content world, so the page's
/// cookies go along and its scripts can't interfere) and handed back as HTML for `RedditPages`. A blocked answer (Reddit's
/// block page, a 403 or 429) loads a page again once before giving up.
///
/// X: X draws everything in the browser, so the view opens the search or the post itself and keeps X's own answer to it
/// (`TweetDetail`, `SearchTimeline`) for `XPages`; without one it waits for posts to appear, scrolls a few times (X keeps
/// only the cells near the viewport) and hands back the timeline's cells. Once a view is on x.com it moves to the next page
/// inside X's app (as following a link there does), which skips loading X again; a page X has already shown in that view
/// is loaded afresh, since X would show it from memory without asking. A post's replies and Explore's search have a view
/// of their own and Topics' searches another, so the reader never waits behind a topic refresh; each view reads one page
/// at a time, and a page read in the last few minutes is reused. It needs the user signed in to X in the app (`WebAccount.x`).
///
/// Instagram: one view opens an account's profile, one at a time, and hands back the links to the posts it drew (`InstagramFeed`).
/// It reads no more than a visitor sees and needs no sign-in unless Instagram asks a visitor for one.
///
/// Who you follow (`DefaultFollowReader`): X's Following page, Instagram's following list and YouTube's channel list, read once when
/// asked, through the sign-in. These need a session and read more than anything else here, so they go slowly and stop at a refusal.
///
/// Images, media and fonts are never loaded. Everything here runs on the main actor; the views are made on first use.
@MainActor
public final class DiscussionWeb: NSObject {
    public static let shared = DiscussionWeb()

    private var reddit: SiteView?
    private var redditReady = false
    /// The load passing Reddit's challenge: those asking meanwhile wait for it, since another load would cancel it.
    private var redditWarming: Task<SiteView, any Error>?
    /// Post pages fetched in the last few minutes: the reader asks for a post's body and its comments separately.
    private var redditPages: [String: (at: Date, html: String)] = [:]
    private static let pageLifetime: TimeInterval = 180
    /// How long a page moved to inside X's app has to answer before it is loaded afresh.
    private static let xInPageWait: TimeInterval = 6
    /// X's views: the reader's and Explore's, and Topics'.
    private let xFront = XLane()
    private let xBack = XLane()
    /// X pages read in the last few minutes (those X answered), by address.
    private var xPages: [String: (at: Date, page: XPage)] = [:]
    private var instagram: SiteView?
    /// The profiles waiting for Instagram's view.
    private var instagramQueue: Task<Void, Never>?
    private var youtube: SiteView?
    private var rules: WKContentRuleList?
    private var rulesLoaded = false

    private static let world = WKContentWorld.world(name: "OpenDispatchDiscussions")
    private let log = Logger(subsystem: "com.gauthamv.openfeed", category: "discussions")

    /// Drops a site's view, so the next use starts fresh (after signing in or out).
    public func forget(_ account: WebAccount) {
        switch account {
        case .reddit:
            reddit = nil
            redditReady = false
        case .x:
            for lane in [xFront, xBack] { lane.view = nil }
            xPages = [:]
        case .instagram:
            instagram = nil
        case .youtube:
            youtube = nil
        }
    }

    // MARK: Reddit

    /// The HTML at `path` on reddit.com; a POST of `form` (with Reddit's CSRF token added) when it is given.
    func redditHTML(_ path: String, form: [String: String]? = nil) async throws -> String {
        try Self.requireForeground()
        let cached = form == nil && RedditPages.isThread(RedditPages.origin + path)
        if cached, let page = redditPages[path], Date().timeIntervalSince(page.at) < Self.pageLifetime { return page.html }
        for attempt in 0..<2 {
            let view = try await redditView(warmingWith: path, force: attempt > 0)
            let answer = try await fetch(path, form: form, in: view)
            if !Self.isRedditBlock(status: answer.status, text: answer.text) {
                if answer.status == 404 { throw DiscussionError.notFound }
                if cached {
                    redditPages = redditPages.filter { Date().timeIntervalSince($0.value.at) < Self.pageLifetime }
                    redditPages[path] = (Date(), answer.text)
                }
                return answer.text
            }
            redditReady = false
        }
        throw DiscussionError.blocked(.reddit)
    }

    private func redditView(warmingWith path: String, force: Bool) async throws -> SiteView {
        if let redditWarming { return try await redditWarming.value }
        if let view = reddit, !view.terminated, redditReady, !force { return view }
        // A page load passes the challenge; the page asked for is as good as any, unless it isn't a page.
        let page = path.hasPrefix("/svc/") || path.contains("/.rss") || path.contains(".json") ? "/" : path
        let warming = Task { @MainActor in
            defer { redditWarming = nil }
            let view: SiteView
            if let existing = reddit, !existing.terminated {
                view = existing
            } else {
                view = await newView(.reddit)
                reddit = view
            }
            redditReady = false
            try await view.load(URL(string: RedditPages.origin + page)!)
            try await view.waitUntil(timeout: 15) { view in
                let state = try await view.call("""
                    return document.readyState === "complete" && !document.querySelector("input[name=solution]") && location.hostname.endsWith("reddit.com")
                    """, in: Self.world)
                return state as? Bool == true
            }
            redditReady = true
            return view
        }
        redditWarming = warming
        return try await warming.value
    }

    nonisolated static func isRedditBlock(status: Int, text: String) -> Bool {
        // The challenge is a small page that solves a puzzle into a "solution" field; every real page also names the
        // challenge in its scripts, so the name alone says nothing.
        status == 403 || status == 429 || text.contains("blocked by network security")
            || (text.utf8.count < 30_000 && text.contains("\"solution\""))
    }

    private func fetch(_ path: String, form: [String: String]?, in view: SiteView) async throws -> (status: Int, text: String) {
        let script = """
            const options = { credentials: "include", cache: "no-cache" };
            if (post) {
              const csrf = (document.cookie.match(/(?:^|; )csrf_token=([^;]+)/) || [])[1] || "";
              const body = new URLSearchParams(form);
              body.set("csrf_token", csrf);
              options.method = "POST";
              options.headers = { "content-type": "application/x-www-form-urlencoded" };
              options.body = body.toString();
            }
            const r = await fetch(path, options);
            return { status: r.status, text: await r.text() };
            """
        let value = try await view.call(script, arguments: ["path": path, "post": form != nil, "form": form ?? [:]], in: Self.world, timeout: 20)
        guard let dict = value as? [String: Any], let text = dict["text"] as? String else { throw DiscussionError.blocked(.reddit) }
        return ((dict["status"] as? NSNumber)?.intValue ?? 0, text)
    }

    // MARK: X

    /// What an X page gave: the answers of X's own `TweetDetail` (a post) or `SearchTimeline` (a search) requests, read first,
    /// and the timeline cells it drew, the fallback when there were none.
    struct XPage: Sendable {
        var answers: [Data]
        var cells: [String]
    }

    /// One of X's hidden views and the pages waiting for it.
    private final class XLane {
        var view: SiteView?
        var queue: Task<Void, Never>?
        /// The pages X's app has shown in `view` since it last loaded x.com.
        var shown: Set<String> = []
    }

    /// An X page, after waiting for X's answer (or, without one, for posts to be drawn, scrolling `scrolls` times).
    /// `background` reads it in Topics' view.
    func xPage(_ url: String, scrolls: Int, background: Bool = false) async throws -> XPage {
        try Self.requireForeground()
        guard await WebAccount.x.isSignedIn() else { throw DiscussionError.signInRequired(.x) }
        if let cached = xPages[url], Date().timeIntervalSince(cached.at) < Self.pageLifetime { return cached.page }
        let lane = background ? xBack : xFront
        let previous = lane.queue
        let task = Task { @MainActor () throws -> XPage in
            _ = await previous?.value
            let page = try await self.readX(url, scrolls: scrolls, in: lane)
            if !page.answers.isEmpty {
                self.xPages = self.xPages.filter { Date().timeIntervalSince($0.value.at) < Self.pageLifetime }
                self.xPages[url] = (Date(), page)
            }
            return page
        }
        lane.queue = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Keeps the answers of X's `TweetDetail`, `SearchTimeline`, `Following` and `UserByScreenName` requests in `window.__odx` as the page makes them (the page's
    /// own world: its requests go through the page's XMLHttpRequest and fetch).
    private static let xCapture = """
        (() => {
          const ops = /\\/(TweetDetail|SearchTimeline|Following|UserByScreenName)\\b/;
          const keep = (u, body) => { const m = ops.exec(u); if (m) (window.__odx = window.__odx || []).push({ op: m[1], u, body }); };
          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, u) {
            this.addEventListener("load", () => { try { keep(String(u), this.responseText); } catch (e) {} });
            return open.apply(this, arguments);
          };
          const f = window.fetch;
          window.fetch = function (input) {
            const u = (input && input.url) || String(input);
            const p = f.apply(this, arguments);
            if (ops.test(u)) p.then((r) => r.clone().text()).then((t) => keep(u, t)).catch(() => {});
            return p;
          };
        })();
        """

    private func readX(_ url: String, scrolls: Int, in lane: XLane) async throws -> XPage {
        guard let target = URL(string: url), let parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            throw DiscussionError.notFound
        }
        let started = Date()
        let view = await xView(lane)
        let id = XPages.statusID(url)
        let op = id != nil ? "TweetDetail" : "SearchTimeline"
        // A post's answer names the post; a search's is the only one since the page changed.
        let answers = "return (window.__odx || []).filter((a) => a.op === op && a.u.includes(id)).map((a) => a.body);"
        let arguments: [String: Any] = ["op": op, "id": id ?? ""]
        var bodies: [String] = []
        let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        if let current = view.webView.url, current.host == "x.com", !current.path.hasPrefix("/i/flow/"), lane.shown.insert(path).inserted {
            _ = try? await view.call("""
                window.__odx = [];
                history.pushState({}, "", path);
                dispatchEvent(new PopStateEvent("popstate", { state: {} }));
                return true;
                """, arguments: ["path": path], in: .page)
            try? await view.waitUntil(timeout: Self.xInPageWait, every: 0.1) { view in
                bodies = (try? await view.call(answers, arguments: arguments, in: .page) as? [String]) ?? []
                return !bodies.isEmpty
            }
        }
        if !bodies.isEmpty {
            log.info("x \(url, privacy: .public) \(op, privacy: .public) answers \(bodies.count) in page, \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return XPage(answers: bodies.map { Data($0.utf8) }, cells: [])
        }
        try await view.load(target)
        lane.shown = [path]
        var found: [String] = []
        var seen = Set<String>()
        let collect = """
            const wall = location.pathname.startsWith("/i/flow/login") || !!document.querySelector("[data-testid=loginButton]");
            const cells = [...document.querySelectorAll("[data-testid=cellInnerDiv]")].map((c) => {
              const copy = c.cloneNode(true);
              copy.querySelectorAll("svg, style, script, video").forEach((n) => n.remove());
              return copy.outerHTML;
            });
            const empty = !!document.querySelector("[data-testid=emptyState], [data-testid=error-detail]");
            return { wall, empty, cells, posts: document.querySelectorAll("article[data-testid=tweet]").length };
            """
        var wall = false
        var empty = false
        try await view.waitUntil(timeout: 15, every: 0.1) { view in
            bodies = (try? await view.call(answers, arguments: arguments, in: .page) as? [String]) ?? []
            if !bodies.isEmpty { return true }
            let r = try await view.call(collect, in: Self.world) as? [String: Any]
            wall = r?["wall"] as? Bool == true
            empty = r?["empty"] as? Bool == true
            return wall || empty
        }
        if wall { throw DiscussionError.signInRequired(.x) }
        if !bodies.isEmpty {
            log.info("x \(url, privacy: .public) \(op, privacy: .public) answers \(bodies.count), \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return XPage(answers: bodies.map { Data($0.utf8) }, cells: [])
        }
        // A post's page draws the post first and its replies a moment later.
        if XPages.statusID(url) != nil, !empty {
            try? await view.waitUntil(timeout: 8) { view in
                let r = try await view.call("return document.querySelectorAll('article[data-testid=tweet]').length;", in: Self.world)
                return ((r as? NSNumber)?.intValue ?? 0) > 1
            }
        }
        for step in 0...scrolls {
            if step > 0 {
                _ = try? await view.call("window.scrollBy(0, window.innerHeight * 2); return true;", in: Self.world)
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
            let r = try await view.call(collect, in: Self.world) as? [String: Any]
            // Cells are keyed by the post they hold; an empty cell (a group's end) by the post before it.
            var last = "start"
            for cell in r?["cells"] as? [String] ?? [] {
                let key = Self.statusKey(cell).map { "post:" + $0 } ?? "after:" + last
                if let id = Self.statusKey(cell) { last = id }
                if seen.insert(key).inserted { found.append(cell) }
            }
            let href = (try? await view.call("return location.href", in: Self.world)) as? String ?? "?"
            log.info("x \(url, privacy: .public) step \(step) cells \((r?["cells"] as? [String])?.count ?? -1) posts \((r?["posts"] as? NSNumber)?.intValue ?? -1) empty \(empty) at \(href, privacy: .public)")
        }
        log.info("x \(url, privacy: .public) no \(op, privacy: .public); kept \(found.count) cells, posts \(found.compactMap(Self.statusKey).joined(separator: " "), privacy: .public)")
        return XPage(answers: [], cells: found)
    }

    nonisolated private static let statusHref = ExtractionDOM.Pattern(#"href="(/[^/"]+/status/\d+)""#)

    /// The address of the post a cell holds: the first status link (the one around its time).
    nonisolated static func statusKey(_ cell: String) -> String? {
        guard cell.contains("data-testid=\"tweet\"") else { return nil }
        return statusHref.firstMatch(cell)?[1] ?? nil
    }

    // MARK: Instagram

    /// The links to the posts on a profile, or nil when a page can't run now (a background refresh, which isn't a failure of the source).
    func instagramPostLinks(_ handle: String) async throws -> [String]? {
        guard (try? Self.requireForeground()) != nil else { return nil }
        let previous = instagramQueue
        let task = Task { @MainActor () throws -> [String] in
            _ = await previous?.value
            return try await self.readInstagram(handle)
        }
        instagramQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func readInstagram(_ handle: String) async throws -> [String] {
        let view: SiteView
        if let existing = instagram, !existing.terminated {
            view = existing
        } else {
            view = await newView(.instagram)
            instagram = view
        }
        try await view.load(URL(string: InstagramFeed.profileURL(handle))!)
        let read = """
            const links = [...document.querySelectorAll('a[href*="/p/"], a[href*="/reel/"]')].map((a) => a.getAttribute("href"));
            const text = document.body ? document.body.innerText : "";
            const wall = location.pathname.startsWith("/accounts/login") || !!document.querySelector("input[name=password], input[name=pass]");
            return { links, wall, closed: /account is private/i.test(text), gone: /page isn.t available/i.test(text) };
            """
        var links: [String] = []
        var page: [String: Any] = [:]
        let started = Date()
        try? await view.waitUntil(timeout: 15) { view in
            page = try await view.call(read, in: Self.world) as? [String: Any] ?? [:]
            links = page["links"] as? [String] ?? []
            return !links.isEmpty || page["closed"] as? Bool == true || page["gone"] as? Bool == true
                || (page["wall"] as? Bool == true && Date().timeIntervalSince(started) > 3)
        }
        if !links.isEmpty {
            // The grid draws row by row.
            try await Task.sleep(nanoseconds: 500_000_000)
            let last = try? await view.call(read, in: Self.world) as? [String: Any]
            return last?["links"] as? [String] ?? links
        }
        log.info("instagram \(handle, privacy: .public) no posts at \(view.webView.url?.absoluteString ?? "?", privacy: .public)")
        if page["closed"] as? Bool == true { throw FeedDetectionError("This Instagram account is private.") }
        if page["gone"] as? Bool == true { throw FeedDetectionError("Instagram has no account named @\(handle).") }
        if page["wall"] as? Bool == true {
            throw FeedDetectionError("Instagram asked for a sign-in to show this account. Sign in under Settings \u{203A} Integrations.")
        }
        throw FeedDetectionError("Instagram didn\u{2019}t show this account\u{2019}s posts. Trying again at the next refresh.")
    }

    // MARK: Who you follow

    /// What X's Following page gave: its answers, and the account's own profile answer, which says how many it follows.
    struct XFollowingPages: Sendable {
        var answers: [Data]
        var profile: Data?
    }

    /// Everyone the signed-in account follows on X, up to about `maxAccounts`, the latest follows first: opens the account's own Following
    /// page in Topics' view and scrolls it at a reading pace, keeping X's answers.
    func xFollowing(maxAccounts: Int, progress: @escaping @Sendable (Int) -> Void) async throws -> XFollowingPages {
        try Self.requireForeground()
        guard await WebAccount.x.isSignedIn() else { throw DiscussionError.signInRequired(.x) }
        let lane = xBack
        let previous = lane.queue
        let task = Task { @MainActor () throws -> XFollowingPages in
            _ = await previous?.value
            return try await self.readXFollowing(maxAccounts: maxAccounts, in: lane, progress: progress)
        }
        lane.queue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func readXFollowing(maxAccounts: Int, in lane: XLane, progress: @Sendable (Int) -> Void) async throws -> XFollowingPages {
        let view = await xView(lane)
        lane.shown = []
        try await view.load(URL(string: XPages.origin + "/home")!)
        var handle: String?
        var wall = false
        try? await view.waitUntil(timeout: 15) { view in
            let r = try await view.call("""
                const a = document.querySelector("a[data-testid=AppTabBar_Profile_Link], a[data-testid=DashButton_ProfileIcon_Link]");
                return { handle: a ? a.getAttribute("href") : "", wall: location.pathname.startsWith("/i/flow/login") || !!document.querySelector("[data-testid=loginButton]") };
                """, in: Self.world) as? [String: Any]
            wall = r?["wall"] as? Bool == true
            let href = r?["handle"] as? String ?? ""
            handle = href.isEmpty ? nil : String(href.drop { $0 == "/" })
            return wall || handle != nil
        }
        if wall { throw DiscussionError.signInRequired(.x) }
        guard let handle else { throw FeedDetectionError("X didn\u{2019}t say which account is signed in. Try again in a minute.") }

        try await view.load(URL(string: "\(XPages.origin)/\(handle)/following")!)
        var answers: [Data] = []
        var profile: Data?
        var read = 0
        /// Takes the answers X has made since the last look.
        func collect() async throws -> Int {
            let r = try await view.call("""
                const all = window.__odx || [];
                return all.slice(from).filter((a) => a.op === "Following" || a.op === "UserByScreenName").map((a) => [a.op, a.body]).concat([["count", String(all.length)]]);
                """, arguments: ["from": read], in: .page) as? [[String]] ?? []
            for pair in r where pair.count == 2 {
                switch pair[0] {
                case "Following": answers.append(Data(pair[1].utf8))
                case "UserByScreenName": profile = Data(pair[1].utf8)
                default: read = Int(pair[1]) ?? read
                }
            }
            return XPages.following(inAnswers: answers).count
        }
        try await view.waitUntil(timeout: 15, every: 0.3) { _ in try await collect() > 0 }
        var found = try await collect()
        progress(found)
        var stalled = 0
        while found < maxAccounts, stalled < 3 {
            _ = try? await view.call("window.scrollBy(0, window.innerHeight * 2); return true;", in: Self.world)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let now = try await collect()
            stalled = now == found ? stalled + 1 : 0
            found = now
            progress(found)
        }
        log.info("x following: \(found) accounts from \(answers.count) answers")
        return XFollowingPages(answers: answers, profile: profile)
    }

    /// Pages of who the signed-in account follows on Instagram, up to about `maxAccounts`, read slowly: this is the app's biggest
    /// request of Instagram, made once and only when asked, and it stops at the first refusal.
    func instagramFollowing(maxAccounts: Int, progress: @escaping @Sendable (Int) -> Void) async throws -> [Data] {
        try Self.requireForeground()
        let previous = instagramQueue
        let task = Task { @MainActor () throws -> [Data] in
            _ = await previous?.value
            return try await self.readInstagramFollowing(maxAccounts: maxAccounts, progress: progress)
        }
        instagramQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func readInstagramFollowing(maxAccounts: Int, progress: @Sendable (Int) -> Void) async throws -> [Data] {
        let cookies = await WebAccount.cookies()
        guard await WebAccount.instagram.isSignedIn(),
              let user = cookies.first(where: { $0.name == "ds_user_id" && $0.domain.hasSuffix("instagram.com") })?.value else {
            throw DiscussionError.signInRequired(.instagram)
        }
        let view: SiteView
        if let existing = instagram, !existing.terminated {
            view = existing
        } else {
            view = await newView(.instagram)
            instagram = view
        }
        try await view.load(URL(string: "https://www.instagram.com/")!)
        let script = """
            const r = await fetch(path, { credentials: "include", headers: { "X-IG-App-ID": "936619743392459", "X-Requested-With": "XMLHttpRequest" } });
            return { status: r.status, text: await r.text() };
            """
        var pages: [Data] = []
        var found = 0
        var next: String?
        repeat {
            let after = next.map { "&max_id=\($0)" } ?? ""
            let answer = try await view.call(script, arguments: ["path": "/api/v1/friendships/\(user)/following/?count=50\(after)"], in: Self.world, timeout: 20) as? [String: Any]
            let data = Data((answer?["text"] as? String ?? "").utf8)
            guard (answer?["status"] as? NSNumber)?.intValue == 200, let page = FollowPages.instagram(data) else {
                log.info("instagram following stopped: status \((answer?["status"] as? NSNumber)?.intValue ?? 0)")
                if pages.isEmpty {
                    throw FeedDetectionError("Instagram didn\u{2019}t share your list. It may want you to confirm it\u{2019}s you in its app. Try again later.")
                }
                break
            }
            pages.append(data)
            found += page.accounts.count
            progress(found)
            next = page.next
            if next != nil, found < maxAccounts { try await Task.sleep(nanoseconds: 2_500_000_000) }
        } while next != nil && found < maxAccounts
        return pages
    }

    /// Keeps the answers of YouTube's `browse` requests, which bring more of a list as it scrolls, in `window.__odyt`.
    private static let youtubeCapture = """
        (() => {
          const f = window.fetch;
          window.fetch = function (input) {
            const u = (input && input.url) || String(input);
            const p = f.apply(this, arguments);
            if (u.includes("/youtubei/v1/browse")) p.then((r) => r.clone().text()).then((t) => (window.__odyt = window.__odyt || []).push(t)).catch(() => {});
            return p;
          };
        })();
        """

    /// The signed-in account's channel list (`/feed/channels`, most relevant first) as the page's own data and the answers that
    /// brought more of it as it scrolled. The first page is the part that matters, so a list that won't scroll is still useful.
    func youtubeSubscriptions(progress: @escaping @Sendable (Int) -> Void) async throws -> [Data] {
        try Self.requireForeground()
        let view: SiteView
        if let existing = youtube, !existing.terminated {
            view = existing
        } else {
            view = await newView(.youtube)
            youtube = view
        }
        try await view.load(URL(string: "https://www.youtube.com/feed/channels")!)
        var first: String?
        try? await view.waitUntil(timeout: 15) { view in
            if view.webView.url?.host?.hasSuffix("accounts.google.com") == true { return true }
            first = try await view.call("return window.ytInitialData ? JSON.stringify(window.ytInitialData) : null;", in: .page) as? String
            return first != nil
        }
        if view.webView.url?.host?.hasSuffix("accounts.google.com") == true { throw DiscussionError.signInRequired(.youtube) }
        guard let first else { throw FeedDetectionError("YouTube didn\u{2019}t show your subscriptions. Try again in a minute.") }
        var bodies = [Data(first.utf8)]
        var found = FollowPages.youtube(bodies).count
        progress(found)
        var stalled = 0
        while stalled < 2 {
            _ = try? await view.call("window.scrollTo(0, document.documentElement.scrollHeight); return true;", in: .page)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let more = try? await view.call("const a = window.__odyt || []; window.__odyt = []; return a;", in: .page) as? [String]
            bodies += (more ?? []).map { Data($0.utf8) }
            let now = FollowPages.youtube(bodies).count
            stalled = now == found ? stalled + 1 : 0
            found = now
            progress(found)
        }
        return bodies
    }

    /// A web view's pages don't run while an iPhone app is in the background (a background refresh), so don't start one.
    private static func requireForeground() throws {
        #if os(iOS)
        if UIApplication.shared.applicationState == .background { throw DiscussionError.unavailable }
        #endif
    }

    // MARK: Views

    /// Opens Reddit's view and, signed in, X's front one ahead of a search, so the first search moves inside the page instead of loading the
    /// site. For a screen about to search both, which are about a second faster for it.
    public func warmForSearch() {
        guard (try? Self.requireForeground()) != nil else { return }
        Task { _ = try? await self.redditView(warmingWith: "/", force: false) }
        let lane = xFront
        let previous = lane.queue
        lane.queue = Task { @MainActor in
            _ = await previous?.value
            guard await WebAccount.x.isSignedIn() else { return }
            let view = await self.xView(lane)
            guard view.webView.url?.host != "x.com" else { return }
            try? await view.load(URL(string: XPages.origin + "/settings")!)
            lane.shown = []
        }
    }

    private func xView(_ lane: XLane) async -> SiteView {
        if let view = lane.view, !view.terminated { return view }
        let view = await newView(.x)
        lane.view = view
        lane.shown = []
        return view
    }

    private func newView(_ account: WebAccount) async -> SiteView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebAccount.dataStore
        #if os(iOS)
        config.allowsInlineMediaPlayback = false
        #endif
        config.mediaTypesRequiringUserActionForPlayback = .all
        if let rules = await contentRules() { config.userContentController.add(rules) }
        if account == .x {
            config.userContentController.addUserScript(WKUserScript(source: Self.xCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if account == .youtube {
            config.userContentController.addUserScript(WKUserScript(source: Self.youtubeCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let agent = switch account {
        case .reddit: String?.none
        case .youtube: WebAccount.desktopUserAgent
        case .x, .instagram: WebAccount.browserUserAgent
        }
        return SiteView(configuration: config, userAgent: agent)
    }

    /// Blocks images, media and fonts in the hidden views; nil if WebKit won't compile the rules.
    func contentRules() async -> WKContentRuleList? {
        if rulesLoaded { return rules }
        let json = #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
        rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "OpenDispatchDiscussions", encodedContentRuleList: json)
        rulesLoaded = true
        return rules
    }
}

/// What a script returned: property-list values (strings, numbers, arrays, dictionaries), which nothing else holds.
struct ScriptValue: @unchecked Sendable {
    let value: Any?
}

/// One hidden web view: loads a page and waits for it, and runs JavaScript with a timeout.
@MainActor
final class SiteView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var terminated = false
    private var waiting: CheckedContinuation<Void, any Error>?
    private var loads = 0

    init(configuration: WKWebViewConfiguration, userAgent: String?) {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1600), configuration: configuration)
        super.init()
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
    }

    /// Loads `url` and returns once the first page has finished (a challenge page may then move on by itself).
    func load(_ url: URL, timeout: TimeInterval = 20) async throws {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
        loads += 1
        let load = loads
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            waiting = cont
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.loads == load else { return }
                    self.finish(DiscussionError.unavailable)
                }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let cont = waiting else { return }
        waiting = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// Polls `ready` every `interval` seconds until it says so; throws after `timeout`.
    func waitUntil(timeout: TimeInterval, every interval: TimeInterval = 0.3, _ ready: (SiteView) async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await ready(self)) == true { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw DiscussionError.unavailable
    }

    /// Runs an async function body. The Objective-C entry point (`__callAsyncJavaScript`), as in `ReadabilityWebView`:
    /// the Swift overlay's isn't on iOS 18.
    func call(_ script: String, arguments: [String: Any] = [:], in world: WKContentWorld, timeout: TimeInterval = 10) async throws -> Any? {
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScriptValue, any Error>) in
            var done = false
            webView.__callAsyncJavaScript(script, arguments: arguments, inFrame: nil, in: world) { value, error in
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ScriptValue(value: value)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard !done else { return }
                    done = true
                    cont.resume(throwing: DiscussionError.unavailable)
                }
            }
        }
        return result.value
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            // A page that hands over to another before loading (a redirect by script) isn't a failure.
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish(error)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            terminated = true
            finish(DiscussionError.unavailable)
        }
    }
}
#endif
