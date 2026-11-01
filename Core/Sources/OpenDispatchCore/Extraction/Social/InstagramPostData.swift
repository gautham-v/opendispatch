import Foundation

/// What Instagram's post page carries as page data for a link-preview crawler (`xig_polaris_media`, the answer the page draws from):
/// the exact time, the whole caption, every photo of a carousel, a reel's video, the author, and the first comments. A post that
/// is gated leaves out all but the comments, and `PreviewTagPost` falls back on the preview tags.
struct InstagramPostData {
    typealias Media = SocialPost.Media

    var handle: String?
    var name: String?
    var avatar: String?
    var caption: String?
    var date: Date?
    var media: [Media] = []
    var commentCount: Int?
    var comments: [DiscussionEntry] = []

    private static let script = ExtractionDOM.Pattern(#"(?s)<script type="application/json"[^>]*>(.*?)</script>"#)

    /// The page's data, or nil when the page has none (Instagram changed it, or this isn't a post's page).
    static func parse(html: String, canonical: String) -> InstagramPostData? {
        guard let data = pageData(html) else { return nil }
        var out = InstagramPostData()
        let post = data["if_not_gated_logged_out"] as? [String: Any]
        if let user = post?["user"] as? [String: Any] {
            out.handle = user["username"] as? String
            out.name = (user["full_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.avatar = user["profile_pic_url"] as? String
        }
        out.caption = (post?["caption"] as? [String: Any])?["text"] as? String
        out.date = (post?["taken_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        out.commentCount = (post?["comment_count"] as? NSNumber)?.intValue
        if let post { out.media = media(of: post) }
        let edges = (data["comments_connection"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        out.comments = edges.compactMap { ($0["node"] as? [String: Any]).flatMap { comment($0, postHandle: out.handle, canonical: canonical) } }
        return out
    }

    /// The comments of a post's page for the reader.
    static func thread(html: String, canonical: String) -> DiscussionThread {
        let data = parse(html: html, canonical: canonical)
        return DiscussionThread(entries: data?.comments ?? [], total: data?.commentCount)
    }

    private static func pageData(_ html: String) -> [String: Any]? {
        for match in script.regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html), html[range].contains("xig_polaris_media"),
                  let json = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)), let found = find("xig_polaris_media", in: json) else { continue }
            return found
        }
        return nil
    }

    private static func find(_ key: String, in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] as? [String: Any] { return found }
            for child in dict.values { if let found = find(key, in: child) { return found } }
        } else if let list = value as? [Any] {
            for child in list { if let found = find(key, in: child) { return found } }
        }
        return nil
    }

    /// A carousel's photos and videos, or the post's own.
    private static func media(of post: [String: Any]) -> [Media] {
        let carousel = post["carousel_media"] as? [[String: Any]] ?? []
        return (carousel.isEmpty ? [post] : carousel).compactMap(item)
    }

    private static func item(_ media: [String: Any]) -> Media? {
        let candidates = (media["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]]
        let picture = (media["display_uri"] as? String) ?? candidates?.first?["url"] as? String
        let width = (media["original_width"] as? NSNumber)?.intValue
        let height = (media["original_height"] as? NSNumber)?.intValue
        if let video = (media["video_versions"] as? [[String: Any]])?.first?["url"] as? String {
            return Media(kind: .video, url: video, poster: picture, width: width, height: height)
        }
        return picture.map { Media(kind: .photo, url: $0, width: width, height: height) }
    }

    private static func comment(_ node: [String: Any], postHandle: String?, canonical: String) -> DiscussionEntry? {
        guard node["is_covered"] as? Bool != true, let id = node["pk"] as? String, let text = node["text"] as? String,
              let user = node["user"] as? [String: Any], let username = user["username"] as? String else { return nil }
        let html = SocialPost.paragraphs(fromPlain: text).map { "<p>\($0)</p>" }.joined()
        return .comment(DiscussionComment(
            id: id, author: "@\(username)", avatarUrl: user["profile_pic_url"] as? String, body: RichText.html(html),
            published: (node["created_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            score: (node["comment_like_count"] as? NSNumber)?.intValue, depth: 0, url: canonical + "c/\(id)/", byAuthor: username == postHandle))
    }
}
