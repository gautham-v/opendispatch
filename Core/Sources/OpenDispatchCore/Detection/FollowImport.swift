import Foundation

/// The apps a new reader can bring who they follow from (`DefaultFollowReader`). YouTube, Instagram, X and Reddit are read through
/// the app's own sign-in, in a hidden web view; Substack and Bluesky lists are public and only need a handle. Everything is read
/// on the device, once, when asked. Threads, TikTok, LinkedIn, Facebook and Twitch aren't here since the app has no feed for them.
public enum FollowApp: String, CaseIterable, Identifiable, Sendable {
    case youtube, instagram, x, reddit, substack, bluesky

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .x: "X"
        case .reddit: "Reddit"
        case .substack: "Substack"
        case .bluesky: "Bluesky"
        }
    }

    /// For its favicon.
    public var host: String {
        switch self {
        case .youtube: "youtube.com"
        case .instagram: "instagram.com"
        case .x: "x.com"
        case .reddit: "reddit.com"
        case .substack: "substack.com"
        case .bluesky: "bsky.app"
        }
    }

    /// The sign-in its list needs; nil for a public list, read by handle.
    public var account: WebAccount? {
        switch self {
        case .youtube: .youtube
        case .instagram: .instagram
        case .x: .x
        case .reddit: .reddit
        case .substack, .bluesky: nil
        }
    }

    /// How many start turned on. Instagram's are fewer: each opens a hidden web view on every refresh, one at a time.
    public var shortlistSize: Int { self == .instagram ? 12 : 24 }

    public var handlePlaceholder: String {
        self == .bluesky ? "you.bsky.social" : "yourhandle"
    }

    public var handleHint: String {
        self == .bluesky
            ? "No sign-in needed. Bluesky\u{2019}s follow lists are public."
            : "No sign-in needed. Only the subscriptions you show on your profile come through."
    }

    /// "Who you follow on X", "Your YouTube subscriptions".
    public var listTitle: String {
        switch self {
        case .youtube, .substack: "Your \(name) subscriptions"
        case .reddit: "Your Reddit communities"
        case .instagram, .x, .bluesky: "Who you follow on \(name)"
        }
    }

    var followingVerb: String {
        switch self {
        case .youtube, .substack: "subscribe to"
        case .reddit: "joined"
        case .instagram, .x, .bluesky: "follow"
        }
    }

    /// What the list's own order and audience say about who matters: YouTube lists by relevance and Instagram by its own rank,
    /// X and Bluesky put the latest follows first, Reddit lists by name.
    var rankWeights: (position: Double, audience: Double) {
        switch self {
        case .youtube, .instagram, .substack: (1, 0)
        case .x, .bluesky: (0.5, 0.5)
        case .reddit: (0, 1)
        }
    }

    /// Accounts this small are mostly people's friends. Reddit communities and channels aren't, and the others have no counts.
    var dropsSmallAccounts: Bool { self == .x || self == .bluesky }
}

/// One account from a follow list.
public struct FollowedAccount: Sendable, Equatable {
    public var result: SourceSearchResult
    public var followers: Int?
    public var isPrivate: Bool
    public var isVerified: Bool

    public init(result: SourceSearchResult, followers: Int? = nil, isPrivate: Bool = false, isVerified: Bool = false) {
        self.result = result
        self.followers = followers
        self.isPrivate = isPrivate
        self.isVerified = isVerified
    }
}

/// A list as read: the accounts in the app's own order, and how many are followed, when the app says.
public struct FollowRead: Sendable, Equatable {
    public var accounts: [FollowedAccount]
    public var followedTotal: Int?

    public init(accounts: [FollowedAccount], followedTotal: Int? = nil) {
        self.accounts = accounts
        self.followedTotal = followedTotal
    }
}

/// A list ready for review: what can be read, best first, with the first `shortlistCount` turned on.
public struct FollowList: Sendable, Equatable {
    public let app: FollowApp
    public let ranked: [SourceSearchResult]
    public let shortlistCount: Int
    /// How many are followed: what the app says, or what was read.
    public let total: Int
    /// The app said how many, so `total` isn't just as far as the read got.
    public let totalIsKnown: Bool
    /// Private accounts and accounts under 1K followers among those read.
    public let leftOut: Int
    /// Accounts by feed URL that were also found on another app: their name.
    public let alsoOn: [String: String]

    public var shortlist: [SourceSearchResult] { Array(ranked.prefix(shortlistCount)) }
    public var rest: [SourceSearchResult] { Array(ranked.dropFirst(shortlistCount)) }
}

/// Turns a read list into the shortlist: leaves out what can't or shouldn't be read, then ranks by the app's own order and audience,
/// with anyone also followed on another connected app first.
public enum FollowRanking {
    /// `elsewhere`: names on the lists already read, as `normalized(_:)` gives them, with the app each came from.
    public static func list(_ app: FollowApp, read: FollowRead, elsewhere: [String: String] = [:]) -> FollowList {
        let readable = read.accounts.filter { account in
            guard !account.isPrivate else { return false }
            if app.dropsSmallAccounts, let followers = account.followers, followers < 1_000 { return false }
            return true
        }
        let weights = app.rankWeights
        let last = max(readable.count - 1, 1)
        var alsoOn: [String: String] = [:]
        let scored = readable.enumerated().map { index, account -> (index: Int, score: Double, result: SourceSearchResult) in
            let position = 1 - Double(index) / Double(last)
            let audience = account.followers.map { min(log10(Double(max($0, 1))) / 8, 1) } ?? 0
            var score = weights.position * position + weights.audience * audience
            if account.isVerified { score += 0.15 }
            if let other = elsewhere[normalized(account.result.title)] {
                score += 1
                alsoOn[account.result.feedUrl] = other
            }
            return (index, score, account.result)
        }
        let ranked = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.result)
        return FollowList(app: app, ranked: ranked, shortlistCount: min(app.shortlistSize, ranked.count),
                          total: max(read.followedTotal ?? 0, read.accounts.count), totalIsKnown: read.followedTotal != nil, leftOut: read.accounts.count - readable.count, alsoOn: alsoOn)
    }

    /// A name for matching one person across apps.
    public static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// The sentence under a list's title.
    public static func summary(_ list: FollowList) -> String {
        let on = list.shortlistCount
        if list.ranked.isEmpty { return "Nothing here can be read." }
        if on == list.total { return "All \(on) are turned on." }
        let count = list.total.formatted(.number)
        let lead = list.totalIsKnown ? "You \(list.app.followingVerb) \(count)." : "Found \(count)."
        return on == 1 ? "\(lead) This one is turned on." : "\(lead) These \(on) are turned on."
    }
}

/// Handles as people type them: "@you", a profile link.
public enum FollowHandle {
    public static func cleaned(_ typed: String, for app: FollowApp) -> String {
        var handle = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = handle.range(of: app == .bluesky ? "/profile/" : "/@") { handle = String(handle[range.upperBound...]) }
        handle = handle.split(separator: "/").first.map(String.init) ?? handle
        if handle.hasPrefix("@") { handle.removeFirst() }
        if app == .bluesky, !handle.isEmpty, !handle.contains(".") { handle += ".bsky.social" }
        return handle
    }
}

/// Parsers for the answers each app gives. Pure, for the tests.
enum FollowPages {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Instagram

    /// A page of `/api/v1/friendships/<id>/following/`.
    static func instagram(_ data: Data) -> (accounts: [FollowedAccount], next: String?)? {
        guard let json = object(data), let users = json["users"] as? [[String: Any]] else { return nil }
        let accounts = users.compactMap { user -> FollowedAccount? in
            guard let handle = user["username"] as? String, !handle.isEmpty else { return nil }
            let name = (user["full_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? handle
            let url = InstagramFeed.profileURL(handle)
            return FollowedAccount(
                result: SourceSearchResult(title: name, subtitle: "Instagram", feedUrl: url, siteUrl: url, kind: .page,
                                           imageUrl: user["profile_pic_url"] as? String, handle: handle, place: .instagram),
                isPrivate: user["is_private"] as? Bool ?? false, isVerified: user["is_verified"] as? Bool ?? false)
        }
        let next = (json["next_max_id"] as? String) ?? (json["next_max_id"] as? NSNumber)?.stringValue
        return (accounts, next)
    }

    // MARK: YouTube

    /// Every channel in a page's `ytInitialData` or a `browse` answer, wherever it sits, in order.
    static func youtube(_ bodies: [Data]) -> [FollowedAccount] {
        var seen = Set<String>()
        var out: [FollowedAccount] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let channel = dict["channelRenderer"] as? [String: Any] {
                    if let account = youtubeChannel(channel), seen.insert(account.result.feedUrl).inserted { out.append(account) }
                    return
                }
                // Keys in no particular order would lose YouTube's: its lists are arrays, and each item holds one renderer.
                for (_, child) in dict { walk(child) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        for body in bodies {
            if let json = try? JSONSerialization.jsonObject(with: body) { walk(json) }
        }
        return out
    }

    private static func youtubeText(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let text = dict["simpleText"] as? String { return text }
        return (dict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }

    private static func youtubeChannel(_ channel: [String: Any]) -> FollowedAccount? {
        guard let id = channel["channelId"] as? String, let title = youtubeText(channel["title"]), !title.isEmpty else { return nil }
        let texts = [youtubeText(channel["subscriberCountText"]), youtubeText(channel["videoCountText"])].compactMap { $0 }
        let handle = texts.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
        let thumbnails = (channel["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        var avatar = thumbnails?.last?["url"] as? String
        if avatar?.hasPrefix("//") == true { avatar = "https:" + avatar! }
        return FollowedAccount(result: SourceSearchResult(
            title: title, subtitle: "YouTube", feedUrl: FeedDetection.youtubeFeedURL(channelID: id), siteUrl: "https://www.youtube.com/channel/\(id)",
            kind: .youtube, imageUrl: avatar, handle: handle, audience: texts.first { $0.contains("subscriber") }, place: .youtube))
    }

    // MARK: Reddit

    /// A page of `/subreddits/mine/subscriber.json`, leaving out people's profiles and adult communities. Nil when it isn't one
    /// (a signed-out visitor gets a page).
    static func reddit(_ data: Data) -> (accounts: [FollowedAccount], after: String?)? {
        guard let listing = object(data)?["data"] as? [String: Any], let children = listing["children"] as? [[String: Any]] else { return nil }
        let accounts = children.compactMap { child -> FollowedAccount? in
            guard let sub = child["data"] as? [String: Any], let name = sub["display_name"] as? String, !name.hasPrefix("u_"),
                  sub["over18"] as? Bool != true, sub["subreddit_type"] as? String != "user" else { return nil }
            var result = DefaultSocialAccounts.community(name, about: sub["title"] as? String)
            let members = sub["subscribers"] as? Int
            result.audience = members.map { XAccounts.followers($0).replacingOccurrences(of: "follower", with: "member") }
            let icon = [sub["community_icon"] as? String, sub["icon_img"] as? String].compactMap { $0 }.first { !$0.isEmpty }
            result.imageUrl = icon?.replacingOccurrences(of: "&amp;", with: "&")
            return FollowedAccount(result: result, followers: members)
        }
        return (accounts, listing["after"] as? String)
    }

    // MARK: Substack

    /// A public profile's subscriptions. Substack's own newsletter, which everyone gets, is left out.
    static func substack(_ data: Data) -> [FollowedAccount]? {
        guard let json = object(data), let subscriptions = json["subscriptions"] as? [[String: Any]] else { return nil }
        return subscriptions.compactMap { subscription -> FollowedAccount? in
            guard let publication = subscription["publication"] as? [String: Any], let name = publication["name"] as? String,
                  publication["subdomain"] as? String != "on" else { return nil }
            let custom = (publication["custom_domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let host = custom ?? (publication["subdomain"] as? String).map({ "\($0).substack.com" }) else { return nil }
            let site = "https://\(host)"
            return FollowedAccount(result: SourceSearchResult(title: name, subtitle: host, feedUrl: site + "/feed", siteUrl: site, kind: .rss,
                                                              imageUrl: publication["logo_url"] as? String, place: .site))
        }
    }
}

/// Reads who someone follows on an app.
public protocol FollowReading: Sendable {
    /// `handle` for an app with a public list. `progress` gets how many have been found so far.
    func read(_ app: FollowApp, handle: String?, progress: @escaping @Sendable (Int) -> Void) async throws -> FollowRead
}

public struct DefaultFollowReader: FollowReading {
    typealias Fetch = @Sendable (_ url: String) async throws -> (Data, HTTPURLResponse)
    typealias RedditPage = @Sendable (_ path: String) async throws -> String

    static let timeout: TimeInterval = 10
    /// More than a shortlist needs, and few enough to read at an unhurried pace.
    static let maxBluesky = 500
    static let maxReddit = 300
    static let maxX = 500
    static let maxInstagram = 200
    /// Bluesky's lists have no audience, and profiles come 25 a request, so only the latest follows get one.
    static let blueskyProfiles = 150

    let fetch: Fetch
    let redditPage: RedditPage

    public init() {
        self.init(fetch: { url in try await HTTP.fetch(url, timeout: Self.timeout, headers: ["Accept": "application/json"]) }, redditPage: { path in
            #if canImport(WebKit)
            return try await DiscussionWeb.shared.redditHTML(path)
            #else
            throw DiscussionError.unavailable
            #endif
        })
    }

    /// Tests inject a fake network.
    init(fetch: @escaping Fetch, redditPage: @escaping RedditPage) {
        self.fetch = fetch
        self.redditPage = redditPage
    }

    public func read(_ app: FollowApp, handle: String?, progress: @escaping @Sendable (Int) -> Void) async throws -> FollowRead {
        switch app {
        case .bluesky: return try await bluesky(handle ?? "", progress: progress)
        case .substack: return try await substack(handle ?? "", progress: progress)
        case .reddit: return try await reddit(progress: progress)
        case .x, .instagram, .youtube:
            #if canImport(WebKit)
            return try await webList(app, progress: progress)
            #else
            throw DiscussionError.unavailable
            #endif
        }
    }

    #if canImport(WebKit)
    private func webList(_ app: FollowApp, progress: @escaping @Sendable (Int) -> Void) async throws -> FollowRead {
        switch app {
        case .x:
            let pages = try await DiscussionWeb.shared.xFollowing(maxAccounts: Self.maxX, progress: progress)
            return FollowRead(accounts: XPages.following(inAnswers: pages.answers), followedTotal: pages.profile.flatMap(XPages.followingCount(inProfile:)))
        case .instagram:
            let pages = try await DiscussionWeb.shared.instagramFollowing(maxAccounts: Self.maxInstagram, progress: progress)
            return FollowRead(accounts: pages.flatMap { FollowPages.instagram($0)?.accounts ?? [] })
        default:
            let accounts = FollowPages.youtube(try await DiscussionWeb.shared.youtubeSubscriptions(progress: progress))
            guard !accounts.isEmpty else { throw FeedDetectionError("YouTube didn\u{2019}t list any subscriptions.") }
            return FollowRead(accounts: accounts)
        }
    }
    #endif

    // MARK: Public lists

    private struct BlueskyFollows: Decodable {
        let follows: [DefaultSocialAccounts.BlueskyActors.Actor]
        let cursor: String?
    }

    private struct BlueskyOwner: Decodable {
        let followsCount: Int?
    }

    private struct BlueskyOwners: Decodable {
        let profiles: [BlueskyOwner]
    }

    private func answer(_ url: String, missing: String) async throws -> Data {
        let (data, res) = try await fetch(url)
        if res.statusCode == 400 || res.statusCode == 404 { throw FeedDetectionError(missing) }
        guard (200..<300).contains(res.statusCode) else { throw HTTPError.status(res.statusCode) }
        return data
    }

    private func bluesky(_ typed: String, progress: @Sendable (Int) -> Void) async throws -> FollowRead {
        let handle = FollowHandle.cleaned(typed, for: .bluesky)
        guard !handle.isEmpty else { throw FeedDetectionError("Type your Bluesky handle.") }
        let app = DefaultSocialAccounts.appView
        let missing = "Bluesky has no account named @\(handle)."
        let owner = try JSONDecoder().decode(BlueskyOwners.self, from: try await answer(
            "\(app)/app.bsky.actor.getProfiles?actors=\(DefaultSocialAccounts.encoded(handle))", missing: missing))
        guard let total = owner.profiles.first?.followsCount else { throw FeedDetectionError(missing) }

        var actors: [DefaultSocialAccounts.BlueskyActors.Actor] = []
        var cursor: String?
        repeat {
            let after = cursor.map { "&cursor=\(DefaultSocialAccounts.encoded($0))" } ?? ""
            let page = try JSONDecoder().decode(BlueskyFollows.self, from: try await answer(
                "\(app)/app.bsky.graph.getFollows?actor=\(DefaultSocialAccounts.encoded(handle))&limit=100\(after)", missing: missing))
            actors += page.follows
            progress(actors.count)
            cursor = page.follows.isEmpty ? nil : page.cursor
        } while cursor != nil && actors.count < Self.maxBluesky

        var audience: [String: Int] = [:]
        for start in stride(from: 0, to: min(actors.count, Self.blueskyProfiles), by: 25) {
            let batch = actors[start..<min(start + 25, actors.count)].map { "actors=\(DefaultSocialAccounts.encoded($0.did))" }.joined(separator: "&")
            guard let data = try? await answer("\(app)/app.bsky.actor.getProfiles?\(batch)", missing: missing),
                  let profiles = try? JSONDecoder().decode(DefaultSocialAccounts.BlueskyActors.self, from: data).profiles else { continue }
            for profile in profiles { audience[profile.did] = profile.followersCount }
        }
        let accounts = actors.map { actor -> FollowedAccount in
            var result = DefaultSocialAccounts.blueskyResult(actor)
            let followers = audience[actor.did]
            result.audience = followers.map(XAccounts.followers)
            return FollowedAccount(result: result, followers: followers)
        }
        return FollowRead(accounts: accounts, followedTotal: total)
    }

    private func substack(_ typed: String, progress: @Sendable (Int) -> Void) async throws -> FollowRead {
        let handle = FollowHandle.cleaned(typed, for: .substack)
        guard !handle.isEmpty else { throw FeedDetectionError("Type your Substack handle.") }
        let data = try await answer("https://substack.com/api/v1/user/\(DefaultSocialAccounts.encoded(handle))/public_profile",
                                    missing: "Substack has no profile named @\(handle).")
        guard let accounts = FollowPages.substack(data) else { throw FeedDetectionError("Substack didn\u{2019}t list any subscriptions for @\(handle).") }
        progress(accounts.count)
        return FollowRead(accounts: accounts)
    }

    // MARK: Reddit

    private func reddit(progress: @Sendable (Int) -> Void) async throws -> FollowRead {
        var accounts: [FollowedAccount] = []
        var after: String?
        repeat {
            let next = after.map { "&after=\($0)" } ?? ""
            let text = try await redditPage("/subreddits/mine/subscriber.json?limit=100\(next)")
            guard let page = FollowPages.reddit(Data(text.utf8)) else {
                if accounts.isEmpty { throw DiscussionError.signInRequired(.reddit) }
                break
            }
            accounts += page.accounts
            progress(accounts.count)
            after = page.after
        } while after != nil && accounts.count < Self.maxReddit
        return FollowRead(accounts: accounts)
    }
}
