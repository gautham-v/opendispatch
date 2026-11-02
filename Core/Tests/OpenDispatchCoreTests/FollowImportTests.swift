import Foundation
import Testing
@testable import OpenDispatchCore

@Suite("Follow import")
struct FollowImportTests {
    private static func x(_ name: String, followers: Int? = 50_000, isPrivate: Bool = false) -> FollowedAccount {
        FollowedAccount(result: XAccounts.result(name: name, handle: name.replacingOccurrences(of: " ", with: ""), followers: followers, avatar: nil),
                        followers: followers, isPrivate: isPrivate)
    }

    private static func response(_ url: String, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: Ranking

    @Test func leavesOutPrivateAndSmallAccountsAndCountsThem() {
        let list = FollowRanking.list(.x, read: FollowRead(accounts: [
            Self.x("Open"), Self.x("Locked", isPrivate: true), Self.x("Friend", followers: 412), Self.x("No Count", followers: nil),
        ], followedTotal: 1240))
        #expect(list.ranked.map(\.title).sorted() == ["No Count", "Open"])
        #expect(list.leftOut == 2)
        #expect(list.total == 1240)
    }

    @Test func aSmallCommunityStays() {
        let small = FollowedAccount(result: DefaultSocialAccounts.community("swiftpm"), followers: 300)
        #expect(FollowRanking.list(.reddit, read: FollowRead(accounts: [small])).ranked.count == 1)
    }

    @Test func shortlistStopsAtTheAppsSize() {
        let accounts = (0..<40).map { Self.x("Person \($0)") }
        #expect(FollowRanking.list(.x, read: FollowRead(accounts: accounts)).shortlistCount == 24)
        #expect(FollowRanking.list(.instagram, read: FollowRead(accounts: accounts)).shortlistCount == 12)
        #expect(FollowRanking.list(.x, read: FollowRead(accounts: Array(accounts.prefix(5)))).shortlistCount == 5)
    }

    @Test func keepsTheOrderOfAnAppThatRanksItsOwnList() {
        let channels = ["First", "Second", "Third"].map { Self.x($0) }
        #expect(FollowRanking.list(.youtube, read: FollowRead(accounts: channels)).ranked.map(\.title) == ["First", "Second", "Third"])
    }

    @Test func audienceDecidesBetweenFollowsOfAboutTheSameAgeOnX() {
        var accounts = (0..<100).map { Self.x("Person \($0)", followers: 5_000) }
        accounts[3] = Self.x("Small", followers: 1_200)
        accounts[5] = Self.x("Huge", followers: 40_000_000)
        let titles = FollowRanking.list(.x, read: FollowRead(accounts: accounts)).ranked.map(\.title)
        #expect(titles.first == "Huge")
        #expect(titles.firstIndex(of: "Huge")! < titles.firstIndex(of: "Small")!)
    }

    @Test func aRecentFollowOutranksAFamousOldOneOnX() {
        let accounts = [Self.x("Recent", followers: 20_000)] + (0..<98).map { Self.x("Person \($0)", followers: 5_000) } + [Self.x("Famous Old", followers: 40_000_000)]
        let titles = FollowRanking.list(.x, read: FollowRead(accounts: accounts)).ranked.map(\.title)
        #expect(titles.first == "Recent")
    }

    @Test func someoneFollowedOnAnotherAppComesFirstAndIsNamed() {
        let list = FollowRanking.list(.x, read: FollowRead(accounts: [Self.x("First"), Self.x("Marques Brownlee", followers: 2_000)]),
                                      elsewhere: [FollowRanking.normalized("MARQUES brownlee!"): "YouTube"])
        #expect(list.ranked.first?.title == "Marques Brownlee")
        #expect(list.alsoOn[list.ranked[0].feedUrl] == "YouTube")
    }

    @Test func summaryWords() {
        let few = FollowRanking.list(.x, read: FollowRead(accounts: [Self.x("One"), Self.x("Two")]))
        #expect(FollowRanking.summary(few) == "All 2 are turned on.")
        let many = FollowRanking.list(.x, read: FollowRead(accounts: (0..<40).map { Self.x("P\($0)") }, followedTotal: 1240))
        #expect(FollowRanking.summary(many) == "You follow 1,240. These 24 are turned on.")
        #expect(FollowRanking.summary(FollowRanking.list(.x, read: FollowRead(accounts: []))) == "Nothing here can be read.")
        // Instagram doesn't say how many, and the read stops at a cap.
        let capped = FollowRanking.list(.instagram, read: FollowRead(accounts: (0..<200).map { Self.x("P\($0)") }))
        #expect(FollowRanking.summary(capped) == "Found 200. These 12 are turned on.")
    }

    // MARK: Handles

    @Test func handlesAsTyped() {
        #expect(FollowHandle.cleaned(" @jay.bsky.team ", for: .bluesky) == "jay.bsky.team")
        #expect(FollowHandle.cleaned("jay", for: .bluesky) == "jay.bsky.social")
        #expect(FollowHandle.cleaned("https://bsky.app/profile/jay.bsky.team/", for: .bluesky) == "jay.bsky.team")
        #expect(FollowHandle.cleaned("https://substack.com/@caseynewton", for: .substack) == "caseynewton")
        #expect(FollowHandle.cleaned("", for: .bluesky) == "")
    }

    // MARK: X

    private static func xAnswer(_ users: String) -> Data {
        Data("""
        {"data":{"user":{"result":{"timeline":{"timeline":{"instructions":[{"type":"TimelineClearCache"},{"type":"TimelineAddEntries","entries":[\(users),
        {"entryId":"cursor-bottom-1","content":{"value":"abc"}}]}]}}}}}}
        """.utf8)
    }

    private static func xUser(_ handle: String, followers: Int, protected: Bool = false) -> String {
        """
        {"entryId":"user-\(handle)","content":{"itemContent":{"user_results":{"result":{"rest_id":"1","core":{"screen_name":"\(handle)","name":"\(handle.uppercased())"},
        "avatar":{"image_url":"https://pbs.twimg.com/a_normal.jpg"},"relationship_counts":{"followers":\(followers)},"privacy":{"protected":\(protected)},"verification":{"verified":true}}}}}}
        """
    }

    @Test func xFollowingPages() {
        let first = Self.xAnswer([Self.xUser("simonw", followers: 90_000), Self.xUser("locked", followers: 2_000, protected: true)].joined(separator: ","))
        let second = Self.xAnswer([Self.xUser("SIMONW", followers: 90_000), Self.xUser("gruber", followers: 500_000)].joined(separator: ","))
        let accounts = XPages.following(inAnswers: [first, second])
        #expect(accounts.map { $0.result.handle } == ["simonw", "locked", "gruber"])
        #expect(accounts[0].result.feedUrl == "https://x.com/simonw")
        #expect(accounts[0].followers == 90_000)
        #expect(accounts[0].isVerified)
        #expect(accounts[0].result.imageUrl == "https://pbs.twimg.com/a_bigger.jpg")
        #expect(accounts[1].isPrivate)
    }

    @Test func xFollowingCount() {
        let modern = Data(#"{"data":{"user":{"result":{"relationship_counts":{"following":1240}}}}}"#.utf8)
        let older = Data(#"{"data":{"user":{"result":{"legacy":{"friends_count":88}}}}}"#.utf8)
        #expect(XPages.followingCount(inProfile: modern) == 1240)
        #expect(XPages.followingCount(inProfile: older) == 88)
        #expect(XPages.followingCount(inProfile: Data("{}".utf8)) == nil)
    }

    @Test func peopleSearchStillReads() {
        let results = XPages.accounts(inTimeline: Self.xAnswer(Self.xUser("simonw", followers: 90_000)))
        #expect(results.map(\.feedUrl) == ["https://x.com/simonw"])
        #expect(results[0].audience == "90K followers")
    }

    // MARK: Instagram

    @Test func instagramPage() throws {
        let data = Data("""
        {"users":[{"pk":"1","username":"natgeo","full_name":"National Geographic","is_private":false,"is_verified":true,"profile_pic_url":"https://cdn/a.jpg"},
        {"pk":"2","username":"afriend","full_name":"","is_private":true,"is_verified":false}],"next_max_id":"50","status":"ok"}
        """.utf8)
        let page = try #require(FollowPages.instagram(data))
        #expect(page.next == "50")
        #expect(page.accounts[0].result.title == "National Geographic")
        #expect(page.accounts[0].result.feedUrl == "https://www.instagram.com/natgeo/")
        #expect(page.accounts[0].result.kind == .page)
        #expect(page.accounts[0].isVerified)
        #expect(page.accounts[1].result.title == "afriend")
        #expect(page.accounts[1].isPrivate)
        #expect(FollowPages.instagram(Data(#"{"message":"checkpoint_required"}"#.utf8)) == nil)
    }

    // MARK: YouTube

    @Test func youtubeChannelsWhereverTheySit() {
        let page = Data("""
        {"contents":{"tabs":[{"content":{"items":[
          {"itemSectionRenderer":{"contents":[{"channelRenderer":{"channelId":"UCaaa","title":{"simpleText":"Veritasium"},
            "subscriberCountText":{"simpleText":"@veritasium"},"videoCountText":{"simpleText":"18.2M subscribers"},
            "thumbnail":{"thumbnails":[{"url":"//yt3/small"},{"url":"//yt3/big"}]}}}]}},
          {"itemSectionRenderer":{"contents":[{"channelRenderer":{"channelId":"UCbbb","title":{"runs":[{"text":"Fire"},{"text":"ship"}]}}}]}}
        ]}}]}}
        """.utf8)
        let more = Data(#"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[{"channelRenderer":{"channelId":"UCaaa","title":{"simpleText":"Veritasium"}}},{"channelRenderer":{"channelId":"UCccc","title":{"simpleText":"3Blue1Brown"}}}]}}]}"#.utf8)
        let accounts = FollowPages.youtube([page, more])
        #expect(accounts.map { $0.result.title } == ["Veritasium", "Fireship", "3Blue1Brown"])
        #expect(accounts[0].result.handle == "veritasium")
        #expect(accounts[0].result.audience == "18.2M subscribers")
        #expect(accounts[0].result.imageUrl == "https://yt3/big")
        #expect(accounts[0].result.feedUrl == FeedDetection.youtubeFeedURL(channelID: "UCaaa"))
    }

    // MARK: Reddit

    private static let redditPage = """
    {"kind":"Listing","data":{"after":"t5_2","children":[
      {"kind":"t5","data":{"display_name":"swift","title":"Swift","subscribers":120000,"over18":false,"subreddit_type":"public","community_icon":"https://i/a.png?x=1&amp;y=2","icon_img":""}},
      {"kind":"t5","data":{"display_name":"u_someone","title":"","subscribers":3,"over18":false,"subreddit_type":"user"}},
      {"kind":"t5","data":{"display_name":"nope","title":"","subscribers":3,"over18":true,"subreddit_type":"public"}}
    ]}}
    """

    @Test func redditPage() throws {
        let page = try #require(FollowPages.reddit(Data(Self.redditPage.utf8)))
        #expect(page.after == "t5_2")
        #expect(page.accounts.map { $0.result.title } == ["r/swift"])
        #expect(page.accounts[0].result.feedUrl == "https://www.reddit.com/r/swift/.rss")
        #expect(page.accounts[0].result.audience == "120K members")
        #expect(page.accounts[0].result.imageUrl == "https://i/a.png?x=1&y=2")
        #expect(FollowPages.reddit(Data("<html>sign in</html>".utf8)) == nil)
    }

    @Test func redditSignedOutAsksForASignIn() async {
        let reader = DefaultFollowReader(fetch: { _ in throw HTTPError.status(500) }, redditPage: { _ in "<html>log in</html>" })
        await #expect(throws: DiscussionError.signInRequired(.reddit)) {
            _ = try await reader.read(.reddit, handle: nil, progress: { _ in })
        }
    }

    @Test func redditFollowsItsPages() async throws {
        let last = #"{"data":{"after":null,"children":[{"data":{"display_name":"nba","title":"NBA","subscribers":9000000,"over18":false,"subreddit_type":"public"}}]}}"#
        let reader = DefaultFollowReader(fetch: { _ in throw HTTPError.status(500) }, redditPage: { path in
            path.contains("after=t5_2") ? last : Self.redditPage
        })
        let read = try await reader.read(.reddit, handle: nil, progress: { _ in })
        #expect(read.accounts.map { $0.result.title } == ["r/swift", "r/nba"])
    }

    // MARK: Substack

    @Test func substackProfile() async throws {
        let body = Data("""
        {"subscriptions":[
          {"publication":{"name":"On Substack","subdomain":"on","custom_domain":null}},
          {"publication":{"name":"Slow Boring","subdomain":"slowboring","custom_domain":"www.slowboring.com","logo_url":"https://s/l.png"}},
          {"publication":{"name":"Noahpinion","subdomain":"noahpinion","custom_domain":null}}
        ]}
        """.utf8)
        let reader = DefaultFollowReader(fetch: { url in
            #expect(url == "https://substack.com/api/v1/user/me/public_profile")
            return (body, Self.response(url))
        }, redditPage: { _ in "" })
        let read = try await reader.read(.substack, handle: "@me", progress: { _ in })
        #expect(read.accounts.map { $0.result.feedUrl } == ["https://www.slowboring.com/feed", "https://noahpinion.substack.com/feed"])
        #expect(read.accounts[0].result.place == .site)
    }

    @Test func substackUnknownHandle() async {
        let reader = DefaultFollowReader(fetch: { url in (Data(), Self.response(url, 404)) }, redditPage: { _ in "" })
        await #expect(throws: FeedDetectionError("Substack has no profile named @nobody.")) {
            _ = try await reader.read(.substack, handle: "nobody", progress: { _ in })
        }
    }

    // MARK: Bluesky

    @Test func blueskyPagesAndAudience() async throws {
        let reader = DefaultFollowReader(fetch: { url in
            let body: String
            if url.contains("getFollows"), url.contains("cursor=next") {
                body = #"{"follows":[{"did":"did:plc:b","handle":"b.bsky.social","displayName":"Bee"}]}"#
            } else if url.contains("getFollows") {
                body = #"{"follows":[{"did":"did:plc:a","handle":"a.bsky.social"}],"cursor":"next"}"#
            } else if url.contains("actors=me.bsky.social") {
                body = #"{"profiles":[{"did":"did:plc:me","handle":"me.bsky.social","followsCount":2}]}"#
            } else {
                body = #"{"profiles":[{"did":"did:plc:a","handle":"a.bsky.social","followersCount":4200},{"did":"did:plc:b","handle":"b.bsky.social","followersCount":90}]}"#
            }
            return (Data(body.utf8), Self.response(url))
        }, redditPage: { _ in "" })
        let read = try await reader.read(.bluesky, handle: "me", progress: { _ in })
        #expect(read.followedTotal == 2)
        #expect(read.accounts.map { $0.result.title } == ["a.bsky.social", "Bee"])
        #expect(read.accounts[0].result.feedUrl == "https://bsky.app/profile/did:plc:a/rss")
        #expect(read.accounts[0].followers == 4200)
        #expect(read.accounts[0].result.audience == "4.2K followers")
        // Under 1K comes out when it is ranked.
        #expect(FollowRanking.list(.bluesky, read: read).ranked.map(\.title) == ["a.bsky.social"])
    }

    @Test func blueskyUnknownHandle() async {
        let reader = DefaultFollowReader(fetch: { url in (Data(), Self.response(url, 400)) }, redditPage: { _ in "" })
        await #expect(throws: FeedDetectionError("Bluesky has no account named @nobody.bsky.social.")) {
            _ = try await reader.read(.bluesky, handle: "nobody", progress: { _ in })
        }
    }

    // MARK: Accounts

    @Test func youtubeIsASignIn() {
        #expect(FollowApp.youtube.account == .youtube)
        #expect(FollowApp.bluesky.account == nil)
        #expect(WebAccount.youtube.signOutDomains.contains("google.com"))
    }
}
