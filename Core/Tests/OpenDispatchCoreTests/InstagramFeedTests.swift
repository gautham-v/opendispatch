import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite("Instagram feed")
struct InstagramFeedTests {
    private static func response(_ url: String, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
    }

    /// A post's page as Instagram gives it to a link-preview crawler.
    private static func postPage(day: String, caption: String, image: String = "https://cdn.example/photo.jpg") -> Data {
        Data("""
            <html><head>
            <meta name="twitter:title" content="National Geographic (@natgeo) • Instagram photos and videos" />
            <meta property="og:description" content="3,733 likes, 32 comments - natgeo on \(day): &quot;\(caption)&quot;." />
            <meta property="og:image" content="\(image)" />
            </head></html>
            """.utf8)
    }

    private static let now = ISO8601DateFormatter().date(from: "2026-10-31T09:00:00Z")!

    @Test func onlyAProfileIsAnAccount() {
        #expect(InstagramFeed.handle(ofProfile: "https://www.instagram.com/natgeo/") == "natgeo")
        #expect(InstagramFeed.handle(ofProfile: "https://instagram.com/nat.geo_1?igsh=abc") == "nat.geo_1")
        #expect(InstagramFeed.handle(ofProfile: "https://www.instagram.com/p/abc/") == nil)
        #expect(InstagramFeed.handle(ofProfile: "https://www.instagram.com/explore/") == nil)
        #expect(InstagramFeed.handle(ofProfile: "https://www.instagram.com/") == nil)
        #expect(InstagramFeed.handle(ofProfile: "https://example.com/natgeo/") == nil)
        #expect(FeedDetection.noFeedPlace("https://www.instagram.com/natgeo/") == nil)
        #expect(FeedDetection.noFeedPlace("https://www.instagram.com/p/abc/") == "Instagram")
        #expect(PostSource.isPostURL("https://www.instagram.com/natgeo/"))
    }

    @Test func aProfilesLinksBecomeOnePostAddressEach() {
        let urls = InstagramFeed.postURLs([
            "/natgeo/reel/DfAWxdIFmVB/", "/natgeo/p/DeuOR-CjKE9/", "/disneystudios/reel/DfJThjLOoPn/", "/p/DeuOR-CjKE9/", "/natgeo/",
        ])
        #expect(urls == [
            "https://www.instagram.com/reel/DfAWxdIFmVB/", "https://www.instagram.com/p/DeuOR-CjKE9/", "https://www.instagram.com/reel/DfJThjLOoPn/",
        ])
    }

    @Test func newPostsAreReadAndKnownOnesAreNot() async throws {
        let asked = Asked()
        let result = try await InstagramFeed.read(
            profile: "https://www.instagram.com/natgeo/", known: ["https://www.instagram.com/p/old/"],
            links: { _ in ["/natgeo/p/new1/", "/natgeo/reel/new2/", "/natgeo/p/old/"] },
            fetch: { url, _ in
                await asked.add(url)
                return (Self.postPage(day: url.contains("new1") ? "October 31, 2026" : "October 2, 2026", caption: "About \(url.suffix(5))"), Self.response(url))
            }, now: Self.now)
        #expect(await asked.urls == ["https://www.instagram.com/p/new1/", "https://www.instagram.com/reel/new2/"])
        #expect(result.processed == ["https://www.instagram.com/p/new1/", "https://www.instagram.com/reel/new2/"])
        let first = try #require(result.items.first)
        #expect(first.guid == "https://www.instagram.com/p/new1/")
        #expect(first.title == "About new1/")
        #expect(first.author == "National Geographic (@natgeo)")
        #expect(first.thumbnailUrl == "https://cdn.example/photo.jpg")
        // Today's noon hasn't come yet.
        #expect(first.publishedAt == Self.now)
        #expect(result.items[1].publishedAt < first.publishedAt)
    }

    @Test func aGonePostIsNotAskedForAgainButABusyOneIs() async throws {
        let result = try await InstagramFeed.read(
            profile: "https://www.instagram.com/natgeo/", known: [],
            links: { _ in ["/p/gone/", "/p/busy/", "/p/fine/", "/p/wall/"] },
            fetch: { url, _ in
                if url.contains("gone") { return (Data(), Self.response(url, 404)) }
                if url.contains("busy") { return (Data(), Self.response(url, 429)) }
                if url.contains("wall") { return (Data("<html></html>".utf8), Self.response(url)) }
                return (Self.postPage(day: "October 2, 2026", caption: "Fine"), Self.response(url))
            }, now: Self.now)
        #expect(result.processed == ["https://www.instagram.com/p/gone/", "https://www.instagram.com/p/fine/"])
        #expect(result.items.map(\.title) == ["Fine"])
    }

    @Test func nothingReadableIsAFailure() async {
        await #expect(throws: FeedDetectionError.self) {
            _ = try await InstagramFeed.read(profile: "https://www.instagram.com/natgeo/", known: [], links: { _ in ["/p/a/"] },
                                             fetch: { _, _ in nil }, now: Self.now)
        }
    }

    @Test func aBackgroundRefreshIsNotAFailure() async throws {
        let result = try await InstagramFeed.read(profile: "https://www.instagram.com/natgeo/", known: [], links: { _ in nil },
                                                  fetch: { _, _ in nil }, now: Self.now)
        #expect(result.items.isEmpty)
    }

    @Test func aProfileLinkAddsTheAccount() async throws {
        let detector = DefaultFeedDetector(parser: DefaultFeedParser(), scraper: DefaultPageScraper(), fetch: { url, _ in
            (Data("""
                <html><head><meta property="og:title" content="National Geographic (@natgeo) • Instagram photos and videos" />
                <meta property="og:description" content="284M Followers, 171 Following, 31K Posts" />
                <meta property="og:image" content="https://cdn.example/avatar.jpg" /></head></html>
                """.utf8), Self.response(url))
        })
        let found = try await detector.detect("https://www.instagram.com/natgeo/?hl=en")
        #expect(found.title == "National Geographic")
        #expect(found.feedUrl == "https://www.instagram.com/natgeo/")
        #expect(found.kind == .page)
        #expect(found.iconUrl == "https://cdn.example/avatar.jpg")
    }

    @Test func aMissingAccountIsNotAdded() async {
        let detector = DefaultFeedDetector(parser: DefaultFeedParser(), scraper: DefaultPageScraper(), fetch: { url, _ in
            (Data("<html><head><title>Instagram</title></head></html>".utf8), Self.response(url))
        })
        await #expect(throws: FeedDetectionError("Instagram has no account named @nobody.")) {
            _ = try await detector.detect("https://www.instagram.com/nobody/")
        }
    }

    @Test func aRefreshStoresThePostsAndRemembersThem() async throws {
        let db = try AppDatabase.inMemory()
        let found = DetectedFeed(title: "National Geographic", url: "https://www.instagram.com/natgeo/", feedUrl: "https://www.instagram.com/natgeo/",
                                 kind: .page, group: SourceGroup.blogs)
        let source = try await db.insertSource(found).source
        #expect(source.type == .post)
        let service = DefaultRefreshService(
            database: db, parser: DefaultFeedParser(), scraper: DefaultPageScraper(), fetch: { _, _ in Data() },
            instagramLinks: { _ in ["/natgeo/p/one/", "/natgeo/p/two/"] },
            instagramFetch: { url, _ in (Self.postPage(day: "October 30, 2026", caption: "A post"), Self.response(url)) })
        #expect(try await service.refreshSource(id: source.id) == 2)
        #expect(try await service.refreshSource(id: source.id) == 0)
        let stored = try await db.source(id: source.id)
        #expect(stored?.lastError == nil)
    }
}

private actor Asked {
    var urls: [String] = []
    func add(_ url: String) { urls.append(url) }
}
