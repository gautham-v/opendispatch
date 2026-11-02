import OpenDispatchCore
import SwiftUI

/// The posts opened with Show more, while the app runs. Kept here and not in the row: a list row is rebuilt when it scrolls
/// back into view.
@MainActor @Observable final class ExpandedPosts {
    static let shared = ExpandedPosts()
    private(set) var ids: Set<Int64> = []

    func toggle(_ id: Int64) {
        withAnimation(.snappy(duration: 0.22)) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        }
    }
}

#if os(iOS)
import UIKit

/// How many lines a paragraph takes at a width, measured the way the row draws it, so the row can cut the text at a paragraph
/// end before drawing it. SwiftUI has no way to ask. Kept, since a row's body runs often while the text and width rarely change.
@MainActor private enum PostTextLines {
    private static var known: [String: Int] = [:]

    static func count(_ text: String, font: UIFont, kern: CGFloat, width: CGFloat) -> Int {
        let key = "\(font.fontName)|\(font.pointSize)|\(Int(width))|\(text)"
        if let lines = known[key] { return lines }
        let storage = NSTextStorage(string: text, attributes: [.font: font, .kern: kern])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        if known.count > 2000 { known.removeAll() }
        known[key] = lines
        return lines
    }

    static func font(_ size: CGFloat, _ name: String) -> UIFont {
        UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }
}

/// An iPhone row at Post length Long: up to six lines of the post, stopping at a paragraph end rather than leaving a stray line,
/// its picture or video, the quoted post at three lines, and a one-row link card. Show more opens the row in place.
struct PhoneLongPost<Meta: View>: View {
    let item: FeedItem
    /// A Reddit thread's title, drawn as a heading over its text.
    var heading: String?
    let textColor: Color
    /// Read, and drawn as read: the art fades as a row's thumbnail does.
    let dims: Bool
    let showsMedia: Bool
    let thumbnailScale: CGFloat
    @ViewBuilder let meta: () -> Meta

    /// The row's text width: the list's 8pt inset and the row's 12pt padding on each side of the screen, until it is measured.
    @State private var width = UIScreen.main.bounds.width - 2 * (8 + Metrics.phoneRowPaddingH)

    private static var textCap: Int { 6 }
    private static var quoteCap: Int { 3 }
    private static var textSize: CGFloat { 17 }
    private static var textKern: CGFloat { -0.2 }
    private static var quoteSize: CGFloat { 15.5 }

    private var post: PostPreview { item.item.listPost }
    private var isOpen: Bool { ExpandedPosts.shared.ids.contains(item.id) }
    /// A Reddit post's picture is the feed's small thumbnail until the post is read, too small to draw wide.
    private var sideThumbnail: Bool {
        heading != nil && post.image == nil && item.item.thumbnailUrl?.isEmpty == false && showsMedia
    }

    var body: some View {
        let post = post
        let open = isOpen
        let cut = cut(post, open: open)
        VStack(alignment: .leading, spacing: 10) {
            meta()
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    text(post, plan: cut)
                    if cut.isCut || open { moreButton(open: open) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { new in
                    if abs(new - width) > 0.5 { width = new }
                }
                if sideThumbnail {
                    ItemThumbnail(item: item, style: .square, scale: thumbnailScale).opacity(dims ? 0.55 : 1)
                }
            }
            if showsMedia, let image = post.image { media(image, isVideo: post.isVideo) }
            if let quote = post.quote { PostQuoteCard(quote: quote, open: open, width: width, showsMedia: showsMedia, dims: dims) }
            if let card = post.card { PostLinkCard(card: card, open: open, showsMedia: showsMedia, dims: dims) }
        }
    }

    // MARK: Text

    /// What the text column draws: the heading, if any, then the paragraphs.
    private func blocks(_ post: PostPreview) -> [(text: String, isHeading: Bool)] {
        // A Reddit post of only a title reads like a post, in the regular weight; a title over text is its heading.
        let head = heading.map { [(text: $0, isHeading: !post.paragraphs.isEmpty)] } ?? []
        return head + post.paragraphs.map { (text: $0, isHeading: false) }
    }

    private func cut(_ post: PostPreview, open: Bool) -> PostCut.Plan {
        let blocks = blocks(post)
        guard !open else { return PostCut.Plan(visible: blocks.count, lastLineLimit: nil, isCut: false) }
        let regular = PostTextLines.font(Self.textSize, "Figtree-Regular")
        let bold = PostTextLines.font(Self.textSize, "Figtree-SemiBold")
        let lines = blocks.map { PostTextLines.count($0.text, font: $0.isHeading ? bold : regular, kern: Self.textKern, width: width) }
        return PostCut.plan(lineCounts: lines, cap: Self.textCap, clean: true)
    }

    private func text(_ post: PostPreview, plan: PostCut.Plan) -> some View {
        let shown = Array(blocks(post).prefix(plan.visible).enumerated())
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(shown, id: \.offset) { index, block in
                Text(PostLinks.styled(block.text, links: post.links))
                    .font(block.isHeading && !dims ? OFFont.phoneItemTitle : OFFont.phonePostText)
                    .tracking(Self.textKern)
                    .lineSpacing(2)
                    .foregroundStyle(textColor)
                    .lineLimit(index == shown.count - 1 ? plan.lastLineLimit : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func moreButton(open: Bool) -> some View {
        // A tap gesture, not a Button: the whole row is a button that opens the post, and a button inside it doesn't get the tap.
        // VoiceOver has this as the row's action (`ItemRowView`).
        Text(open ? "Show less" : "Show more")
            .font(OFFont.ui(15.5, .medium))
            .foregroundStyle(.ofMuted)
            .padding(.vertical, 8)
            .padding(.trailing, 24)
            .contentShape(Rectangle())
            .onTapGesture { ExpandedPosts.shared.toggle(item.id) }
            .padding(.vertical, -10)
    }

    private func media(_ image: String, isVideo: Bool) -> some View {
        PostMediaFrame(url: image, isVideo: isVideo, radius: Metrics.phoneVideoRadius, playSize: 48)
            .opacity(dims ? 0.55 : 1)
    }
}

/// Link text in the accent color; the row itself is what's tapped.
private enum PostLinks {
    static func styled(_ text: String, links: [String]) -> AttributedString {
        var out = AttributedString(text)
        for link in links {
            var from = out.startIndex
            while from < out.endIndex, let range = out[from...].range(of: link) {
                out[range].foregroundColor = Color.ofAccent
                from = range.upperBound
            }
        }
        return out
    }
}

/// A picture or video still, full width at 16:9.
private struct PostMediaFrame: View {
    let url: String
    let isVideo: Bool
    let radius: CGFloat
    let playSize: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.ofCode
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                CachedAsyncImage(url: URL(string: url), maxPixelSize: 400 * max(displayScale, 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.ofCode
                }
            }
            .overlay { if isVideo { PostPlayGlyph(size: playSize) } }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct PostPlayGlyph: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .frame(width: size, height: size)
            .overlay(
                OFIcon.play.image
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.025)
            )
    }
}

/// The quoted post: its author, three lines of its text with its picture or video small beside them. Whole, and the picture wide,
/// once the row is open.
private struct PostQuoteCard: View {
    let quote: PostPreview.Quote
    let open: Bool
    /// The row's text width.
    let width: CGFloat
    let showsMedia: Bool
    let dims: Bool
    @Environment(\.displayScale) private var displayScale

    private static var padding: CGFloat { 12 }
    private static var sideImage: CGFloat { 64 }
    private static var cap: Int { 3 }

    private var image: String? { showsMedia ? quote.image : nil }

    var body: some View {
        let plan = cut()
        VStack(alignment: .leading, spacing: 6) {
            who
            HStack(alignment: .top, spacing: 10) {
                if !quote.paragraphs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        let shown = Array(quote.paragraphs.prefix(plan.visible).enumerated())
                        ForEach(shown, id: \.offset) { index, paragraph in
                            Text(PostLinks.styled(paragraph, links: quote.links))
                                .font(OFFont.ui(15.5))
                                .lineSpacing(2)
                                .foregroundStyle(.ofBody)
                                .lineLimit(index == shown.count - 1 ? plan.lastLineLimit : nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !open, let image { sideThumbnail(image) }
            }
            if open, let image {
                PostMediaFrame(url: image, isVideo: quote.isVideo, radius: 8, playSize: 40)
                    .opacity(dims ? 0.55 : 1)
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ofHairline, lineWidth: 1)
        }
    }

    /// Cut anywhere, as X does: the card isn't the post, and the row opens for the rest.
    private func cut() -> PostCut.Plan {
        guard !open else { return PostCut.Plan(visible: quote.paragraphs.count, lastLineLimit: nil, isCut: false) }
        let beside = image == nil ? 0 : Self.sideImage + 10
        let textWidth = width - 2 * Self.padding - beside
        let font = PostTextLines.font(15.5, "Figtree-Regular")
        let lines = quote.paragraphs.map { PostTextLines.count($0, font: font, kern: 0, width: textWidth) }
        return PostCut.plan(lineCounts: lines, cap: Self.cap, clean: false)
    }

    private var who: some View {
        HStack(spacing: 6) {
            CachedAsyncImage(url: quote.avatar.flatMap(URL.init(string:)), maxPixelSize: 18 * max(displayScale, 2)) { image in
                image.resizable().scaledToFill()
            } placeholder: { _ in
                ZStack {
                    Color.ofCode
                    Text(verbatim: String(quote.name.prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.ofMuted)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .accessibilityHidden(true)
            Text(verbatim: quote.name)
                .font(OFFont.ui(13.5, .medium))
                .foregroundStyle(.ofInk)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(verbatim: detail)
                    .font(OFFont.ui(13.5))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
        }
    }

    /// "@handle · Nov 1", the year only when it isn't this one.
    private var detail: String? {
        let thisYear = ", \(Calendar.current.component(.year, from: Date()))"
        let when = quote.when.map { $0.hasSuffix(thisYear) ? String($0.dropLast(thisYear.count)) : $0 }
        let handle = quote.handle.map { $0.hasPrefix("u/") ? $0 : "@\($0)" }
        let parts = [handle, when].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func sideThumbnail(_ image: String) -> some View {
        Color.ofCode
            .frame(width: Self.sideImage, height: Self.sideImage)
            .overlay {
                CachedAsyncImage(url: URL(string: image), maxPixelSize: Self.sideImage * max(displayScale, 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.ofCode
                }
            }
            .overlay { if quote.isVideo { PostPlayGlyph(size: 24) } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(dims ? 0.55 : 1)
    }
}

/// A link card one row high, or only its domain when it has no picture or headline. Its picture runs wide once the row is open.
private struct PostLinkCard: View {
    let card: PostPreview.Card
    let open: Bool
    let showsMedia: Bool
    let dims: Bool
    @Environment(\.displayScale) private var displayScale

    private var image: URL? { showsMedia ? card.image.flatMap(URL.init(string:)) : nil }

    var body: some View {
        if let title = card.title, let image {
            framed {
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.ofCode
                            .aspectRatio(1.91, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay { picture(image) }
                            .clipped()
                            .opacity(dims ? 0.55 : 1)
                        words(title)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                } else {
                    HStack(spacing: 12) {
                        Color.ofCode
                            .frame(width: 88, height: 62)
                            .overlay { picture(image) }
                            .clipped()
                            .opacity(dims ? 0.55 : 1)
                        words(title)
                            .padding(.trailing, 12)
                    }
                }
            }
        } else if let title = card.title {
            framed {
                words(title)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        } else {
            HStack(spacing: 6) {
                OFIcon.link.image
                    .font(.system(size: 12, weight: .medium))
                Text(verbatim: card.domain)
                    .font(OFFont.ui(13.5))
                    .lineLimit(1)
            }
            .foregroundStyle(.ofMuted)
        }
    }

    private func framed(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ofHairline, lineWidth: 1)
            }
    }

    private func picture(_ url: URL) -> some View {
        CachedAsyncImage(url: url, maxPixelSize: 400 * max(displayScale, 2)) { image in
            image.resizable().scaledToFill()
        } placeholder: { _ in
            Color.ofCode
        }
    }

    private func words(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: card.domain)
                .font(OFFont.ui(12.5))
                .foregroundStyle(.ofMuted)
                .lineLimit(1)
            Text(verbatim: title)
                .font(OFFont.ui(15.5))
                .foregroundStyle(.ofInk)
                .lineLimit(open ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
