import Foundation
import GRDB
import Testing
@testable import OpenDispatchCore

@Suite struct PostPreviewTests {
    private static let quotePost = """
        <div class="x-post"><div class="x-who"><img class="x-avatar" src="https://pbs.twimg.com/a.jpg" alt=""><span class="x-name">lauren</span><a class="x-handle" href="https://x.com/poteto">@poteto</a></div>\
        <div class="x-body"><p>wow, played since <a href="http://tibo.dog">tibo.dog</a> launched!</p><p>line one<br>line two</p><ul><li>first</li><li>second</li></ul></div>\
        <div class="x-media"><video src="https://video.twimg.com/v.mp4" poster="https://pbs.twimg.com/still.jpg"></video></div>\
        <div class="x-quote"><div class="x-who"><img class="x-avatar" src="https://pbs.twimg.com/q.jpg" alt=""><span class="x-name">Derrick</span><a class="x-handle" href="https://x.com/d">@d</a><span class="x-when">· Nov 2, 2026</span></div>\
        <div class="x-body"><p>Another week.</p><p>All Pro.</p></div><div class="x-media"><img src="https://pbs.twimg.com/qm.jpg" alt=""></div><a class="x-quote-link" href="https://x.com/d/status/1">View post</a></div>\
        <a class="x-card" href="https://claude.com/a"><img class="x-card-img" src="https://pbs.twimg.com/c.png" alt=""><span class="x-card-text"><span class="x-card-domain">claude.com</span><span class="x-card-title">Message threads</span></span></a>\
        <div class="x-foot"><span>10:51 AM · Nov 2, 2026</span></div></div>
        """

    @Test func readsThePostMarkup() throws {
        let post = try #require(PostPreview.fromMarkup(Self.quotePost))
        #expect(post.paragraphs == ["wow, played since tibo.dog launched!", "line one\nline two", "• first\n• second"])
        #expect(post.links == ["tibo.dog"])
        #expect(post.image == "https://pbs.twimg.com/still.jpg")
        #expect(post.isVideo)
        let quote = try #require(post.quote)
        #expect(quote.name == "Derrick")
        #expect(quote.handle == "d")
        #expect(quote.when == "Nov 2, 2026")
        #expect(quote.avatar == "https://pbs.twimg.com/q.jpg")
        #expect(quote.paragraphs == ["Another week.", "All Pro."])
        #expect(quote.image == "https://pbs.twimg.com/qm.jpg")
        #expect(!quote.isVideo)
        #expect(post.card == PostPreview.Card(domain: "claude.com", title: "Message threads", image: "https://pbs.twimg.com/c.png"))
        #expect(PostPreview(json: post.json) == post)
    }

    @Test func aCardThatOnlyRepeatsItsDomainHasNoTitle() throws {
        let html = #"<div class="x-post"><div class="x-body"><p>a</p></div><a class="x-card" href="https://tibo.dog"><span class="x-card-text"><span class="x-card-domain">tibo.dog</span><span class="x-card-title">tibo.dog</span></span></a></div>"#
        #expect(try #require(PostPreview.fromMarkup(html)).card == PostPreview.Card(domain: "tibo.dog", title: nil, image: nil))
    }

    @Test func anArticleIsNotAPost() {
        #expect(PostPreview.fromMarkup("<p>An article about x-posts.</p>") == nil)
        #expect(PostPreview.fromMarkup(nil) == nil)
    }

    @Test func readsARedditEntryWithoutItsSubmittedLine() throws {
        let html = #"<div class="md"><p>After a slow start.</p><p>Weeks 1-3: 9 catches.</p></div> &#32; submitted by &#32; <a href="https://www.reddit.com/user/a"> /u/a </a>"#
        #expect(try #require(PostPreview.fromFeedHTML(html, root: ".md")).paragraphs == ["After a slow start.", "Weeks 1-3: 9 catches."])
        #expect(PostPreview.fromFeedHTML(#"<table><tr><td>submitted by /u/a</td></tr></table>"#, root: ".md") == nil)
    }

    @Test func readsAFeedEntryWithoutParagraphTags() throws {
        #expect(try #require(PostPreview.fromFeedHTML("first\n\nsecond [contains quote post or other embedded content]")).paragraphs == ["first", "second"])
        #expect(try #require(PostPreview.fromFeedHTML("<p>one</p><p>two<br>three</p>")).paragraphs == ["one", "two\nthree"])
    }

    // MARK: What a row shows

    private func item(url: String, title: String, summary: String? = nil, thumb: String? = nil, avatar: String? = nil, preview: PostPreview? = nil) -> Item {
        Item(sourceId: 1, guid: url, url: url, title: title, summary: summary, publishedAt: Date(timeIntervalSince1970: 0),
             thumbnailUrl: thumb, quoteAvatarUrl: avatar, postPreviewJSON: preview?.json)
    }

    @Test func aPostStoredBeforePreviewsFallsBackToItsRowFields() throws {
        let post = item(url: "https://x.com/a/status/1", title: "Frazier is a freak", summary: "Quoting Derrick: Another week. https://t.co/abc",
                        thumb: "https://pbs.twimg.com/amplify_video_thumb/1/img/a?format=webp&name=small", avatar: "https://pbs.twimg.com/q.jpg").listPost
        #expect(post.paragraphs == ["Frazier is a freak"])
        #expect(post.image == "https://pbs.twimg.com/amplify_video_thumb/1/img/a?format=webp&name=medium")
        #expect(post.isVideo)
        #expect(post.quote?.name == "Derrick")
        #expect(post.quote?.paragraphs == ["Another week."])
        #expect(post.quote?.avatar == "https://pbs.twimg.com/q.jpg")
    }

    @Test func aStoredPreviewWinsAndKeepsItsOwnQuote() throws {
        let stored = PostPreview(paragraphs: ["whole text"], quote: .init(name: "Derrick", paragraphs: ["whole quote", "second"]))
        let post = item(url: "https://x.com/a/status/1", title: "whole…", summary: "Quoting Derrick: whole quote", preview: stored).listPost
        #expect(post.paragraphs == ["whole text"])
        #expect(post.quote?.paragraphs == ["whole quote", "second"])
    }

    @Test func aRedditRowDropsTheTitleAndSubmittedLine() {
        let thread = "https://www.reddit.com/r/nfl/comments/abc/a_title/"
        let opened = PostPreview(paragraphs: ["A title", "The body."])
        #expect(item(url: thread, title: "A title", preview: opened).listPost.paragraphs == ["The body."])
        #expect(item(url: thread, title: "A title", summary: "The body. submitted by /u/a [link] [comments]").listPost.paragraphs == ["The body."])
        #expect(item(url: thread, title: "A title", summary: "submitted by /u/a [link] [comments]").listPost.paragraphs.isEmpty)
    }

    // MARK: The cut

    @Test func stopsAtAParagraphEndRatherThanStrandingALine() {
        // 3 + 2 lines leaves one line of the next paragraph: B2 stops at the paragraph, X's rule keeps the stray line.
        #expect(PostCut.plan(lineCounts: [3, 2, 4], cap: 6, clean: true) == .init(visible: 2, lastLineLimit: nil, isCut: true))
        #expect(PostCut.plan(lineCounts: [3, 2, 4], cap: 6, clean: false) == .init(visible: 3, lastLineLimit: 1, isCut: true))
    }

    @Test func cutsInsideAParagraphWhenTwoOrMoreLinesFit() {
        #expect(PostCut.plan(lineCounts: [3, 5], cap: 6, clean: true) == .init(visible: 2, lastLineLimit: 3, isCut: true))
        #expect(PostCut.plan(lineCounts: [9], cap: 6, clean: true) == .init(visible: 1, lastLineLimit: 6, isCut: true))
    }

    @Test func aPostThatFitsIsNotCut() {
        #expect(PostCut.plan(lineCounts: [3, 3], cap: 6, clean: true) == .init(visible: 2, lastLineLimit: nil, isCut: false))
        #expect(PostCut.plan(lineCounts: [], cap: 6, clean: true) == .init(visible: 0, lastLineLimit: nil, isCut: false))
    }

    // MARK: Storage

    @Test func refreshAndReaderKeepThePreview() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(title: "lauren", url: "https://x.com/poteto", feedUrl: "https://x.com/poteto", kind: .page, group: "x")
            try source.insert(db)
            let parsed = ParsedItem(guid: "a", url: "https://x.com/poteto/status/1", title: "wow…", publishedAt: Date(timeIntervalSince1970: 0),
                                    postPreview: PostPreview(paragraphs: ["wow, all of it"]))
            let row = try #require(try Queries.upsertItems(db, sourceId: source.id, items: [parsed]).first)
            func stored() throws -> PostPreview? { PostPreview(json: try Item.fetchOne(db, key: row.id)?.postPreviewJSON) }
            #expect(try stored()?.paragraphs == ["wow, all of it"])

            // A later refresh that couldn't read the page keeps what was there.
            var again = parsed
            again.postPreview = nil
            try Queries.upsertItems(db, sourceId: source.id, items: [again])
            #expect(try stored()?.paragraphs == ["wow, all of it"])

            // Opening it replaces it with what the reader read; an article's text leaves it alone.
            try Queries.cacheContent(db, itemId: row.id, result: ExtractResult(contentHtml: Self.quotePost, leadImage: nil))
            #expect(try stored()?.quote?.name == "Derrick")
            try Queries.cacheContent(db, itemId: row.id, result: ExtractResult(contentHtml: "<p>text</p>", leadImage: nil))
            #expect(try stored()?.quote?.name == "Derrick")
        }
    }

    @Test func listQueriesCarryThePreview() throws {
        let columns = Item.listSelection.map { String(describing: $0) }.joined()
        #expect(columns.contains("post_preview"))
    }
}
