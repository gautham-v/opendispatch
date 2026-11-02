#if os(macOS)
import AppKit
import OpenDispatchCore
import SwiftUI
import WebKit

/// The floating player: a video that keeps playing on top of every app, in a small window of its own (Mac).
///
/// Popping out moves the reader's playing web view into the window rather than starting a second player, so the video
/// doesn't stop, and its controls, captions, speed and SponsorBlock come with it. The reader is free to show something
/// else meanwhile. Bringing it back opens the item and moves the web view into the reader's player the same way.
@MainActor
@Observable
final class ReaderFloatingPlayer {
    static let shared = ReaderFloatingPlayer()

    /// The video in the window, which the reader replaces with a note when it shows the same one.
    private(set) var videoID: String?
    var isActive: Bool { videoID != nil }
    /// The video whose window was just closed, until the reader showing it has gone back to its poster.
    private(set) var closedVideoID: String?
    @ObservationIgnored private var closedAt: Double = 0

    private struct Session {
        let item: FeedItem
        let videoID: String
        let controller: ReaderYouTubeController
        let coordinator: ReaderYouTubeCoordinator
        let webView: WKWebView
        let panel: ReaderFloatingPanel
        /// Switching apps popped it out, so coming back brings it back.
        let automatic: Bool
    }

    @ObservationIgnored private var session: Session?
    /// On its way back to the reader: for the player the reader is about to make.
    @ObservationIgnored private var returning: Session?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    var controller: ReaderYouTubeController? { session?.controller }

    func controller(forVideo videoID: String) -> ReaderYouTubeController? {
        session?.videoID == videoID ? session?.controller : nil
    }

    func isReturning(_ videoID: String) -> Bool { returning?.videoID == videoID }

    /// Where `videoID` was when its window closed, if that's why it left the window.
    func takeClosed(_ videoID: String) -> Double? {
        guard closedVideoID == videoID else { return nil }
        closedVideoID = nil
        return closedAt
    }

    /// A reader newly showing the video starts as it normally would.
    func clearClosed(_ videoID: String) {
        if closedVideoID == videoID { closedVideoID = nil }
    }

    /// The app's model, for History and the settings; and from here on, popping out on switching apps.
    func attach(_ model: AppModel) {
        self.model = model
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appResigned() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appActivated() }
            },
        ]
    }

    private func appResigned() {
        guard model?.settings.popOutOnAppSwitch == true, session == nil, let player = ReaderYouTubeController.current,
              player.isPlaying else { return }
        player.popOut?(true)
    }

    private func appActivated() {
        if session?.automatic == true { bringBack() }
    }

    /// The menu item and the shortcut: back if one floats, else the reader's video out.
    func toggle() {
        if isActive { bringBack() } else { ReaderYouTubeController.current?.popOut?(false) }
    }

    func popOut(item: FeedItem, vertical: Bool, controller: ReaderYouTubeController, automatic: Bool) {
        guard let videoID = item.item.videoId else { return }
        guard let webView = controller.webView, let coordinator = controller.coordinator else {
            // Still the poster: start it, and out it goes once it plays.
            controller.popOutWhenLoaded = true
            controller.start?(model?.history.resumePosition(item) ?? 0)
            return
        }
        close()
        coordinator.handedOff = true
        coordinator.onEvent = { [weak self] event in self?.handle(event) }
        controller.isFloating = true
        let panel = ReaderFloatingPanel(vertical: vertical, screen: ReaderWindow.current?.screen)
        panel.show(webView)
        session = Session(item: item, videoID: videoID, controller: controller, coordinator: coordinator, webView: webView,
                          panel: panel, automatic: automatic)
        self.videoID = videoID
        webView.evaluateJavaScript("window.odPlayer && window.odPlayer.setFloating(true)")
    }

    /// Opens the item and hands the playing web view to the reader's player, which picks it up as it appears.
    func bringBack() {
        guard let session else { return }
        self.session = nil
        session.panel.close()
        session.webView.evaluateJavaScript("window.odPlayer && window.odPlayer.setFloating(false)")
        session.controller.isFloating = false
        session.controller.webView = nil
        returning = session
        videoID = nil
        if !NSApp.isActive { NSApp.activate() }
        ReaderWindow.current?.makeKeyAndOrderFront(nil)
        model?.open(session.item)
        // No reader took it (the window is gone): it stops rather than play on with nothing showing it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let left = returning, left.webView === session.webView else { return }
            returning = nil
            stop(left)
        }
    }

    /// The reader's player is taking the web view back.
    func takeReturning(videoID: String, into controller: ReaderYouTubeController?) -> ReaderYouTubeCoordinator? {
        guard let session = returning, session.videoID == videoID else { return nil }
        returning = nil
        session.coordinator.handedOff = false
        session.coordinator.returningWebView = session.webView
        controller?.time = session.controller.time
        controller?.duration = session.controller.duration
        controller?.isPlaying = session.controller.isPlaying
        return session.coordinator
    }

    /// Stops the video and closes the window; the reader's poster picks up from where it stopped.
    func close() {
        guard let session else { return }
        self.session = nil
        closedVideoID = session.videoID
        closedAt = session.controller.time
        recordProgress(session, force: true)
        session.panel.close()
        session.controller.isFloating = false
        stop(session)
        videoID = nil
    }

    /// Another video started playing in the reader.
    func pause(unlessShowing videoID: String) {
        guard let session, session.videoID != videoID else { return }
        session.webView.evaluateJavaScript("window.odPlayer && window.odPlayer.pause()")
    }

    private func stop(_ session: Session) {
        session.coordinator.handedOff = false
        session.coordinator.dismantle(session.webView)
        session.webView.removeFromSuperview()
        session.controller.webView = nil
        session.controller.isPlaying = false
    }

    private func handle(_ event: ReaderYouTubeEvent) {
        guard let session else { return }
        switch event {
        case .time(let time, let duration):
            if duration > 0 { session.controller.duration = duration }
            session.controller.time = time
            recordProgress(session)
        case .state(let playing):
            session.controller.isPlaying = playing
        case .popIn:
            bringBack()
        case .floatClose:
            close()
        case .playing, .failed, .blocked, .fullscreen, .exitFullscreen, .popOut:
            break
        }
    }

    private func recordProgress(_ session: Session, force: Bool = false) {
        model?.history.recordProgress(session.item, position: session.controller.time, duration: session.controller.duration, force: force)
    }
}

/// The window. It floats over other apps, full-screen ones and every Space too, and never takes keyboard focus or
/// activates the app: clicking play leaves you typing where you were.
final class ReaderFloatingPanel: NSPanel {
    private static let autosaveName = "FloatingPlayer"
    private static let landscape = NSSize(width: 400, height: 225)
    /// YouTube asks for a player at least 200pt in each direction.
    private static let landscapeMin = NSSize(width: 356, height: 200)
    private static let screenInset: CGFloat = 16

    private let overlay = ReaderFloatingOverlay()
    private let vertical: Bool

    init(vertical: Bool, screen: NSScreen?) {
        self.vertical = vertical
        let size = vertical ? NSSize(width: 270, height: 480) : Self.landscape
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .utilityWindow
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentAspectRatio = size
        minSize = vertical ? NSSize(width: Self.landscapeMin.height, height: Self.landscapeMin.width) : Self.landscapeMin

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        contentView = content
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)

        place(on: screen ?? NSScreen.main, size: size)
    }

    /// Where it last was, or the corner of the screen the reader is on. A Short has its own shape, so starts in the corner.
    private func place(on screen: NSScreen?, size: NSSize) {
        if !vertical {
            let restored = setFrameUsingName(Self.autosaveName)
            setFrameAutosaveName(Self.autosaveName)
            if restored, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return }
        }
        guard let visible = screen?.visibleFrame else { return }
        setFrame(NSRect(x: visible.maxX - size.width - Self.screenInset, y: visible.minY + Self.screenInset,
                        width: size.width, height: size.height), display: false)
    }

    func show(_ webView: WKWebView) {
        guard let content = contentView else { return }
        webView.removeFromSuperview()
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView, positioned: .below, relativeTo: overlay)
        overlay.webView = webView
        orderFrontRegardless()
        invalidateShadow()
    }

    override func close() {
        overlay.webView = nil
        super.close()
    }

    /// Keeps the keyboard with whatever app you're working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A corner dragged by (dx, dy) from `start`, the opposite corner staying put and the shape kept.
    fileprivate func resize(from start: NSRect, corner: (right: Bool, top: Bool), dx: CGFloat, dy: CGFloat) {
        let aspect = contentAspectRatio.width / contentAspectRatio.height
        let byX = corner.right ? dx : -dx, byY = (corner.top ? dy : -dy) * aspect
        let largest = screen?.visibleFrame.width ?? .greatestFiniteMagnitude
        let width = min(largest, max(minSize.width, start.width + (abs(byX) >= abs(byY) ? byX : byY)))
        let height = width / aspect
        setFrame(NSRect(x: corner.right ? start.minX : start.maxX - width, y: corner.top ? start.minY : start.maxY - height,
                        width: width, height: height), display: true)
    }

    /// Lets go of the screen's edge softly: within a few points of one, it sits on it.
    fileprivate func settleOnScreen() {
        guard let visible = screen?.visibleFrame else { return }
        let reach: CGFloat = 16
        var origin = frame.origin
        if abs(origin.x - visible.minX) < reach { origin.x = visible.minX }
        if abs(frame.maxX - visible.maxX) < reach { origin.x = visible.maxX - frame.width }
        if abs(origin.y - visible.minY) < reach { origin.y = visible.minY }
        if abs(frame.maxY - visible.maxY) < reach { origin.y = visible.maxY - frame.height }
        setFrameOrigin(origin)
        if !vertical { saveFrame(usingName: Self.autosaveName) }
    }
}

/// Lies over the web view and takes the mouse. A panel that never becomes key doesn't reliably reach WebKit, which also
/// won't let you drag the window by the video, so this does all of it: a corner resizes, the bar along the bottom gets
/// the mouse as it happens (its scrubber drags), and anywhere else a drag moves the window while a click goes through
/// to the page.
private final class ReaderFloatingOverlay: NSView {
    weak var webView: WKWebView?
    /// How tall the bar is, reaching the scrubber at any window size.
    private static let barHeight: CGFloat = 52

    private static let cornerSize: CGFloat = 16

    private struct Corner {
        let right: Bool, top: Bool

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch (right, top) {
            case (false, false): .bottomLeft
            case (false, true): .topLeft
            case (true, false): .bottomRight
            case (true, true): .topRight
            }
            return .frameResize(position: position, directions: .all)
        }
    }

    private enum Press { case bar, undecided(NSEvent), moving, resizing(Corner) }
    private var press: Press?
    private var grabbedAt = NSPoint.zero
    private var frameAt = NSRect.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }
    override func mouseMoved(with event: NSEvent) {
        webView?.mouseMoved(with: event)
        corner(at: event)?.cursor.set()
    }

    private func corner(at event: NSEvent) -> Corner? {
        let point = convert(event.locationInWindow, from: nil)
        let nearX = point.x < Self.cornerSize || point.x > bounds.width - Self.cornerSize
        let nearY = point.y < Self.cornerSize || point.y > bounds.height - Self.cornerSize
        guard nearX, nearY else { return nil }
        return Corner(right: point.x > bounds.midX, top: point.y > bounds.midY)
    }

    private func setPointerInside(_ inside: Bool) {
        webView?.evaluateJavaScript("window.odPlayer && window.odPlayer.setPointerInside(\(inside))")
    }

    override func mouseDown(with event: NSEvent) {
        grabbedAt = NSEvent.mouseLocation
        frameAt = window?.frame ?? .zero
        if let corner = corner(at: event) {
            press = .resizing(corner)
        } else if convert(event.locationInWindow, from: nil).y < Self.barHeight {
            press = .bar
            webView?.mouseDown(with: event)
        } else {
            press = .undecided(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch press {
        case .bar:
            webView?.mouseDragged(with: event)
        case .undecided:
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x - grabbedAt.x, mouse.y - grabbedAt.y) >= 3 else { return }
            press = .moving
            NSCursor.closedHand.push()
            moveWindow(to: mouse)
        case .moving:
            moveWindow(to: NSEvent.mouseLocation)
        case .resizing(let corner):
            (window as? ReaderFloatingPanel)?.resize(from: frameAt, corner: (right: corner.right, top: corner.top),
                                                     dx: NSEvent.mouseLocation.x - grabbedAt.x, dy: NSEvent.mouseLocation.y - grabbedAt.y)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch press {
        case .bar:
            webView?.mouseUp(with: event)
        case .undecided(let down):
            webView?.mouseDown(with: down)
            webView?.mouseUp(with: event)
        case .moving:
            NSCursor.pop()
            (window as? ReaderFloatingPanel)?.settleOnScreen()
        case .resizing:
            (window as? ReaderFloatingPanel)?.settleOnScreen()
        case nil:
            break
        }
        press = nil
    }

    private func moveWindow(to mouse: NSPoint) {
        window?.setFrameOrigin(NSPoint(x: frameAt.minX + mouse.x - grabbedAt.x, y: frameAt.minY + mouse.y - grabbedAt.y))
    }
}

/// What the reader shows where the player was, while this video floats.
struct ReaderYouTubeFloatingNotice: View {
    let bringBack: () -> Void

    var body: some View {
        Color.black
            .overlay {
                VStack(spacing: 12) {
                    OFIcon.popOut.image
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Playing in the floating player")
                        .font(OFFont.ui(13.5))
                        .foregroundStyle(.white)
                    Button(action: bringBack) {
                        Text("Bring It Back")
                            .font(OFFont.ui(12.5, .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Color.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
    }
}
#endif
