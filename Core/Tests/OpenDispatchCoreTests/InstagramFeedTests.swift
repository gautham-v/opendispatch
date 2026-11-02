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

    /// A post's page with its page data, shaped as Instagram serves it.
    private static let dataPage = #"""
        <html><head><meta name="twitter:title" content="natgeo (@natgeo) • Instagram photos and videos" />
        <meta property="og:description" content="1 likes, 2 comments - natgeo on October 2, 2026: &quot;Short&quot;." />
        <meta property="og:image" content="https://cdn.example/square.jpg" /></head><body>
        <script type="application/json" data-sjs>{"other":1}</script>
        <script type="application/json" data-sjs>{"require":[["x",[{"__bbox":{"result":{"data":{"xig_polaris_media":{
          "if_not_gated_logged_out":{"taken_at":1793474361,"comment_count":76,"caption":{"text":"The whole caption"},
            "user":{"username":"natgeo","full_name":"National Geographic","profile_pic_url":"https://cdn.example/me.jpg"},
            "carousel_media":[
              {"display_uri":"https://cdn.example/1.jpg","original_width":1080,"original_height":1350,"media_type":1},
              {"display_uri":"https://cdn.example/2.jpg","media_type":2,"video_versions":[{"url":"https://cdn.example/2.mp4"}]}]},
          "comments_connection":{"edges":[
            {"node":{"pk":"11","created_at":1793475619,"text":"Lovely","comment_like_count":3,"is_covered":false,"user":{"username":"ann","profile_pic_url":"https://cdn.example/ann.jpg"}}},
            {"node":{"pk":"12","created_at":1793475620,"text":"Hidden","is_covered":true,"user":{"username":"bob"}}},
            {"node":{"pk":"13","created_at":1793475621,"text":"Mine","user":{"username":"natgeo"}}}]}
        }}}}}]]]}</script></body></html>
        """#

    @Test func aPostsPageDataGivesMoreThanItsTags() throws {
        let canonical = "https://www.instagram.com/p/abc/"
        let post = try #require(PreviewTagPost.parse(html: Self.dataPage, canonical: canonical, network: .instagram))
        #expect(post.author.name == "National Geographic")
        #expect(post.author.avatar == "https://cdn.example/me.jpg")
        #expect(post.date == Date(timeIntervalSince1970: 1793474361))
        #expect(post.title == "The whole caption")
        #expect(post.media.map(\.url) == ["https://cdn.example/1.jpg", "https://cdn.example/2.mp4"])
        #expect(post.media[1].kind == .video)
        #expect(post.media[1].poster == "https://cdn.example/2.jpg")
        #expect(post.leadImage == "https://cdn.example/square.jpg")
    }

    /// A carousel's page data as Instagram serves it: every size of each photo, the first being the photo's own.
    private static func carouselPage(likes: String = #""like_count":4003719"#) -> String {
        func photo(_ n: Int) -> String {
            #"{"display_uri":"https://cdn.example/\#(n)-640.jpg","original_width":1177,"original_height":1365,"image_versions2":{"candidates":[{"url":"https://cdn.example/\#(n)-full.jpg"},{"url":"https://cdn.example/\#(n).jpg?stp=dst-jpg_p320x320_tt6"}]}}"#
        }
        return #"""
            <html><head><meta property="og:image" content="https://cdn.example/square.jpg" /></head><body>
            <script type="application/json">{"xig_polaris_media":{"if_not_gated_logged_out":{\#(likes),"taken_at":1793474361,"caption":{"text":"The caption"},
              "user":{"username":"taylorswift","full_name":"Taylor Swift"},"carousel_media":[\#(photo(1)),\#(photo(2))]}}}</script></body></html>
            """#
    }

    @Test func aCarouselUsesEachPhotosOwnSize() throws {
        let post = try #require(PreviewTagPost.parse(html: Self.carouselPage(), canonical: "https://www.instagram.com/p/abc/", network: .instagram))
        #expect(post.media.map(\.url) == ["https://cdn.example/1-full.jpg", "https://cdn.example/2-full.jpg"])
        // The list keeps its small square, and the others their small copies for the strip.
        #expect(post.leadImage == "https://cdn.example/square.jpg")
        #expect(post.media[1].thumb == "https://cdn.example/2.jpg?stp=dst-jpg_p320x320_tt6")
    }

    @Test func aCarouselDrawsAsAGalleryWithThePicturesFirst() throws {
        let post = try #require(PreviewTagPost.parse(html: Self.carouselPage(), canonical: "https://www.instagram.com/p/abc/", network: .instagram))
        let html = try #require(post.render()?.contentHtml)
        #expect(html.contains("x-gallery-track"))
        #expect(!html.contains("x-media-grid"))
        #expect(html.contains("data-thumb=\"https://cdn.example/2.jpg?stp=dst-jpg_p320x320_tt6\""))
        #expect(html.contains("4M likes"))
        let gallery = try #require(html.range(of: "x-gallery")), likes = try #require(html.range(of: "4M likes")), caption = try #require(html.range(of: "The caption"))
        #expect(gallery.lowerBound < likes.lowerBound)
        #expect(likes.lowerBound < caption.lowerBound)
    }

    @Test func hiddenOrNoLikesAreLeftOut() throws {
        for likes in [#""like_count":0"#, #""like_count":5,"like_and_view_counts_disabled":true"#] {
            let post = try #require(PreviewTagPost.parse(html: Self.carouselPage(likes: likes), canonical: "https://www.instagram.com/p/abc/", network: .instagram))
            #expect(post.stats == nil)
        }
    }

    @Test func onePhotoAndOtherNetworksKeepPlainMedia() throws {
        let photo = SocialPost.Media(kind: .photo, url: "https://cdn.example/1.jpg")
        let author = SocialPost.Author(name: "A", handle: "a")
        let single = SocialPost(network: .instagram, url: "https://www.instagram.com/p/a/", author: author, paragraphs: ["Text"], media: [photo])
        #expect(try #require(single.render()?.contentHtml).contains("x-media") && !(single.render()?.contentHtml?.contains("x-gallery") ?? true))
        let threads = SocialPost(network: .threads, url: "https://www.threads.com/@a/post/b", author: author, paragraphs: ["First"], media: [photo, photo])
        let html = try #require(threads.render()?.contentHtml)
        #expect(html.contains("x-media-grid"))
        #expect(!html.contains("x-gallery"))
        let first = try #require(html.range(of: "First")), grid = try #require(html.range(of: "x-media-grid"))
        #expect(first.lowerBound < grid.lowerBound)
    }

    @Test func aPostsCommentsComeFromItsPage() throws {
        let canonical = "https://www.instagram.com/p/abc/"
        #expect(DiscussionPlace.thread(of: canonical) == .instagram)
        #expect(DiscussionPlace.thread(of: "https://www.instagram.com/natgeo/") == nil)
        let thread = InstagramPostData.thread(html: Self.dataPage, canonical: canonical)
        #expect(thread.total == 76)
        let comments = thread.entries.compactMap(\.comment)
        #expect(comments.map(\.author) == ["@ann", "@natgeo"])
        #expect(comments[0].score == 3)
        #expect(comments[0].url == "https://www.instagram.com/p/abc/c/11/")
        #expect(comments[1].byAuthor)
    }

    @Test func aProfileReadsAsItsPostsNewestFirst() async throws {
        let out = try await InstagramFeed.page(handle: "natgeo", links: { _ in ["/natgeo/p/older/", "/natgeo/p/newer/", "/natgeo/p/bad/"] }, fetch: { url, _ in
            if url.contains("bad") { return (Data(), Self.response(url, 404)) }
            return (Self.postPage(day: url.contains("newer") ? "October 30, 2026" : "October 2, 2026", caption: url.contains("newer") ? "Newer" : "Older"), Self.response(url))
        })
        let html = try #require(out.contentHtml)
        let newer = try #require(html.range(of: "Newer")), older = try #require(html.range(of: "Older"))
        #expect(newer.lowerBound < older.lowerBound)
        #expect(html.contains("Open on Instagram"))
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
