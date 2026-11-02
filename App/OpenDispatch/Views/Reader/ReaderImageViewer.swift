import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The images of an article or post, opened from a tap on one (`ReaderHTML.imageTapScript`).
struct ReaderImageGallery: Identifiable, Equatable {
    let id = UUID()
    let urls: [URL]
    let index: Int

    /// The page's message: `{ urls: [String], index: Number }`.
    init?(message body: Any) {
        guard let dict = body as? [String: Any], let strings = dict["urls"] as? [String] else { return nil }
        let urls = strings.compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard !urls.isEmpty else { return nil }
        self.urls = urls
        self.index = min(max(0, (dict["index"] as? NSNumber)?.intValue ?? 0), urls.count - 1)
    }

    /// Where to load `url` from, best first: X serves its photos at full size with `name=orig`, so small text
    /// in a screenshot stays readable when zoomed.
    static func sources(for url: URL) -> [URL] {
        guard url.host?.lowercased() == "pbs.twimg.com",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        var items = (parts.queryItems ?? []).filter { $0.name != "name" }
        items.append(URLQueryItem(name: "name", value: "orig"))
        parts.queryItems = items
        guard let orig = parts.url, orig != url else { return [url] }
        return [orig, url]
    }
}

#if os(iOS)
/// Full screen images: pinch or double-tap to zoom, drag to pan, swipe sideways between a post's images, and
/// drag down (or the close button) to go back to the reader.
struct ReaderImageViewer: View {
    let gallery: ReaderImageGallery

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    /// How far the image is dragged toward dismissing, which fades the backdrop.
    @State private var pull: CGFloat = 0

    init(gallery: ReaderImageGallery) {
        self.gallery = gallery
        _index = State(initialValue: gallery.index)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(1 - min(pull / 400, 0.7))
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(gallery.urls.enumerated()), id: \.offset) { i, url in
                    ReaderZoomableImage(sources: ReaderImageGallery.sources(for: url), onPull: { pull = $0 }, onDismiss: { dismiss() })
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            controls
                .opacity(pull > 4 ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: pull > 4)
        }
        .presentationBackground(.clear)
        .statusBarHidden()
    }

    private var controls: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")
            Spacer()
            if gallery.urls.count > 1 {
                Text("\(index + 1) of \(gallery.urls.count)")
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// One image in a zooming scroll view. Loads the first of `sources` that works.
private struct ReaderZoomableImage: UIViewRepresentable {
    let sources: [URL]
    let onPull: (CGFloat) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ReaderZoomScrollView {
        let view = ReaderZoomScrollView()
        view.onPull = onPull
        view.onDismiss = onDismiss
        view.load(sources)
        return view
    }

    func updateUIView(_ view: ReaderZoomScrollView, context: Context) {
        view.onPull = onPull
        view.onDismiss = onDismiss
    }

    static func dismantleUIView(_ view: ReaderZoomScrollView, coordinator: ()) {
        view.cancel()
    }
}

final class ReaderZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onPull: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?
    /// The bounds the zoom was last fitted to.
    private var fittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // Lets a drag at the fitted size move the image, which is how it is dragged away.
        alwaysBounceVertical = true
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ sources: [URL]) {
        spinner.startAnimating()
        task = Task { [weak self] in
            for url in sources {
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                guard let loaded = try? await URLSession.shared.data(for: request) else { continue }
                if Task.isCancelled { return }
                guard (loaded.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = await Self.decode(loaded.0) else { continue }
                self?.show(image)
                return
            }
            self?.spinner.stopAnimating()
        }
    }

    func cancel() { task?.cancel() }

    /// Decoded off the main thread, so a large photo doesn't hitch the page swipe.
    private nonisolated static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
    }

    private func show(_ image: UIImage) {
        spinner.stopAnimating()
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        fittedSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentOffset.x + bounds.width / 2, y: contentOffset.y + bounds.height / 2)
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0,
              bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 4, 2)
        zoomScale = fit
        center()
    }

    /// Keeps an image smaller than the screen in its middle.
    private func center() {
        let x = max(0, (bounds.width - imageView.frame.width) / 2)
        let y = max(0, (bounds.height - imageView.frame.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    private var atFit: Bool { zoomScale <= minimumZoomScale + 0.001 }

    /// How far a drag at the fitted size has moved the image up or down.
    private var pullDistance: CGFloat { atFit ? abs(contentOffset.y + contentInset.top) : 0 }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if !atFit {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onPull?(pullDistance)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pull = pullDistance
        guard atFit, pull > 90 || (pull > 30 && abs(velocity.y) > 1.2) else { return }
        onDismiss?()
    }
}
#endif

#if os(macOS)
/// The Mac's full-window images, laid over the window that asked: arrows, ← → or a sideways scroll to move, a click on the photo to
/// zoom toward the pointer, Esc, Space, ⌘W, the close button or a click outside the photo to go back. While it is up it takes the
/// keyboard and the scroll wheel, so nothing moves behind it.
@MainActor
enum ReaderImageOverlay {
    private static var host: NSView?
    private static var monitor: Any?
    private static var restoredResponder: NSResponder?
    private static var sideways: CGFloat = 0
    /// This trackpad swipe has moved its one photo.
    private static var swiped = false
    private static let swipeDistance: CGFloat = 60

    static var isOpen: Bool { host != nil }

    static func present(_ gallery: ReaderImageGallery, in window: NSWindow) {
        close()
        guard let content = window.contentView else { return }
        let state = ReaderMacViewerState(gallery: gallery)
        let view = NSHostingView(rootView: ReaderMacImageViewer(state: state, onClose: { close() }))
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .above, relativeTo: nil)
        host = view
        ReaderFittedWebView.setCovered(true, in: window)
        restoredResponder = window.firstResponder
        window.makeFirstResponder(view)
        sideways = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .swipe]) { event in
            MainActor.assumeIsolated { handle(event, state: state, window: window) } ? nil : event
        }
    }

    static func close() {
        guard let view = host else { return }
        let window = view.window
        view.removeFromSuperview()
        host = nil
        ReaderFittedWebView.setCovered(false, in: window)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let restoredResponder { window?.makeFirstResponder(restoredResponder) }
        restoredResponder = nil
    }

    /// True when the event was the viewer's.
    private static func handle(_ event: NSEvent, state: ReaderMacViewerState, window: NSWindow) -> Bool {
        guard host?.window === window else {
            close()
            return false
        }
        guard event.window === window else { return false }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                guard event.charactersIgnoringModifiers?.lowercased() == "w" else { return false }
                close()
                return true
            }
            switch event.keyCode {
            case 53, 49: close()
            case 123: state.move(-1)
            case 124: state.move(1)
            default: break
            }
            return true
        case .swipe:
            if event.deltaX != 0 { state.move(event.deltaX < 0 ? -1 : 1) }
            return true
        case .scrollWheel:
            if event.phase == .began {
                sideways = 0
                swiped = false
            }
            guard event.momentumPhase.isEmpty else { return true }
            sideways += event.scrollingDeltaX
            if !swiped, abs(sideways) > swipeDistance, !state.isZoomed {
                let back = event.isDirectionInvertedFromDevice ? sideways > 0 : sideways < 0
                state.move(back ? -1 : 1)
                sideways = 0
                swiped = !event.phase.isEmpty
            }
            return true
        default:
            return false
        }
    }
}

@MainActor @Observable
private final class ReaderMacViewerState {
    let gallery: ReaderImageGallery
    private(set) var index: Int
    var isZoomed = false
    /// Photos loaded so far, and the ones that wouldn't.
    private(set) var images: [URL: NSImage] = [:]
    private(set) var failed: Set<URL> = []
    @ObservationIgnored private var loading: Set<URL> = []

    init(gallery: ReaderImageGallery) {
        self.gallery = gallery
        index = gallery.index
        loadAround()
    }

    var url: URL { gallery.urls[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < gallery.urls.count - 1 }

    func move(_ by: Int) {
        let next = index + by
        guard gallery.urls.indices.contains(next) else { return }
        index = next
        isZoomed = false
        loadAround()
    }

    /// This photo and its neighbours, so moving on shows the next one at once.
    private func loadAround() {
        for i in [index, index + 1, index - 1] where gallery.urls.indices.contains(i) { load(gallery.urls[i]) }
    }

    private func load(_ url: URL) {
        guard images[url] == nil, !failed.contains(url), loading.insert(url).inserted else { return }
        Task { [weak self] in
            for source in ReaderImageGallery.sources(for: url) {
                var request = URLRequest(url: source, timeoutInterval: 30)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                guard let loaded = try? await URLSession.shared.data(for: request),
                      (loaded.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = NSImage(data: loaded.0) else { continue }
                self?.images[url] = image
                self?.loading.remove(url)
                return
            }
            self?.failed.insert(url)
            self?.loading.remove(url)
        }
    }
}

private struct ReaderMacImageViewer: View {
    let state: ReaderMacViewerState
    let onClose: () -> Void

    /// How far a click zooms, and where in the photo the pointer holds still.
    private static let zoom: CGFloat = 2.4
    @State private var anchor: UnitPoint = .center

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            photo
                .padding(.horizontal, 64)
                .padding(.vertical, 48)
            controls
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var photo: some View {
        if let image = state.images[state.url] {
            GeometryReader { box in
                let fitted = Self.fit(image.size, in: box.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(state.isZoomed ? Self.zoom : 1, anchor: anchor)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let at) = phase {
                            anchor = UnitPoint(x: at.x / max(fitted.width, 1), y: at.y / max(fitted.height, 1))
                        }
                    }
                    .onTapGesture { state.isZoomed.toggle() }
                    .pointerStyle(state.isZoomed ? .zoomOut : .zoomIn)
                    .animation(.easeOut(duration: 0.16), value: state.isZoomed)
                    .position(x: box.size.width / 2, y: box.size.height / 2)
                    .accessibilityLabel("Photo \(state.index + 1) of \(state.gallery.urls.count)")
            }
        } else if state.failed.contains(state.url) {
            Text("This photo couldn\u{2019}t be loaded.")
                .foregroundStyle(.white.opacity(0.7))
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
    }

    /// `size` shown whole inside `box`, up to twice its own size for a small picture.
    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height, 2)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                round("xmark", label: "Close", action: onClose)
            }
            Spacer()
            HStack {
                if state.gallery.urls.count > 1 {
                    round("chevron.left", label: "Previous photo") { state.move(-1) }
                        .opacity(state.canGoBack ? 1 : 0)
                        .disabled(!state.canGoBack)
                    Spacer()
                    round("chevron.right", label: "Next photo") { state.move(1) }
                        .opacity(state.canGoForward ? 1 : 0)
                        .disabled(!state.canGoForward)
                }
            }
            Spacer()
            if state.gallery.urls.count > 1 {
                Text("\(state.index + 1) of \(state.gallery.urls.count)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
        }
        .padding(14)
    }

    private func round(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
