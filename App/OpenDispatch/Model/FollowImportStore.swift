import Foundation
import Observation
import OpenDispatchCore

/// Bringing who you follow in from another app: where each app's list stands and what is turned on in it. The lists stay for as
/// long as the app runs, so going back to one doesn't read it again; nothing is stored. AppModel owns it (`model.followImport`).
@MainActor
@Observable
final class FollowImportStore {
    enum Phase: Equatable {
        case idle
        /// An app with a public list: waiting for a handle.
        case needsHandle
        /// A sign-in or a go-ahead comes first.
        case needsGoAhead
        case reading(found: Int)
        case ready
        case failed(String)
    }

    /// The app on screen in the sheet; nil shows the list of apps.
    var app: FollowApp?
    private(set) var phases: [FollowApp: Phase] = [:]
    private(set) var lists: [FollowApp: FollowList] = [:]
    /// What is turned on in each list, by feed URL.
    private(set) var selected: [FollowApp: Set<String>] = [:]
    /// Lists showing past their shortlist.
    private(set) var expanded: Set<FollowApp> = []
    /// Whether each list goes in a folder named after its app; the default is yes.
    var usesAppFolder: [FollowApp: Bool] = [:]
    /// How many were added from each app.
    private(set) var added: [FollowApp: Int] = [:]
    /// Something came in from an app, so the iPhone's board has no more need of its packs.
    var hasAdded: Bool { !added.isEmpty }
    /// Set when `select` finds the app needs a sign-in, for the sheet to open it.
    var pendingSignIn: WebAccount?

    @ObservationIgnored private let reader: any FollowReading

    init(reader: any FollowReading = DefaultFollowReader()) {
        self.reader = reader
    }

    func phase(_ app: FollowApp) -> Phase { phases[app] ?? .idle }

    /// Opens an app's list: straight to it if it was read, otherwise whatever its list needs first. Instagram always asks first, since
    /// reading the list is a request made of the person's own account.
    func select(_ app: FollowApp) async {
        self.app = app
        switch phase(app) {
        case .ready, .reading: return
        case .idle, .needsHandle, .needsGoAhead, .failed: break
        }
        guard let account = app.account else {
            phases[app] = .needsHandle
            return
        }
        if app == .instagram {
            phases[app] = .needsGoAhead
        } else if await account.isSignedIn() {
            read(app)
        } else {
            phases[app] = .needsGoAhead
            pendingSignIn = account
        }
    }

    /// The sign-in sheet closed. Instagram's go-ahead was already given by the button that opened it.
    func signInClosed(_ app: FollowApp) async {
        guard let account = app.account, await account.isSignedIn() else { return }
        read(app)
    }

    /// The go-ahead's button: sign in first if that is still needed.
    func goAhead(_ app: FollowApp) async {
        guard let account = app.account else { return }
        if await account.isSignedIn() {
            read(app)
        } else {
            pendingSignIn = account
        }
    }

    func submit(handle: String, for app: FollowApp) {
        read(app, handle: handle)
    }

    func tryAgain(_ app: FollowApp) async {
        phases[app] = .idle
        await select(app)
    }

    private func read(_ app: FollowApp, handle: String? = nil) {
        phases[app] = .reading(found: 0)
        let reader = reader
        Task {
            do {
                let read = try await reader.read(app, handle: handle, progress: { found in
                    Task { @MainActor [weak self] in self?.reachedCount(found, in: app) }
                })
                finish(app, read: read)
            } catch DiscussionError.signInRequired {
                // With a session cookie that the site no longer takes, the sign-in sheet would close itself and land back here.
                if let account = app.account, await account.isSignedIn() {
                    phases[app] = .failed("\(app.name) asked for a sign-in again. Sign out under Settings \u{203A} Integrations, then try again.")
                } else {
                    phases[app] = .needsGoAhead
                }
            } catch DiscussionError.unavailable {
                phases[app] = .failed("\(app.name) didn\u{2019}t answer. Try again in a minute.")
            } catch {
                phases[app] = .failed(HTTP.message(error))
            }
        }
    }

    private func reachedCount(_ found: Int, in app: FollowApp) {
        if case .reading = phase(app) { phases[app] = .reading(found: found) }
    }

    private func finish(_ app: FollowApp, read: FollowRead) {
        // Anyone already on another list counts for this one. A list read earlier doesn't change under someone reviewing it.
        var elsewhere: [String: String] = [:]
        for (other, list) in lists where other != app {
            for result in list.ranked { elsewhere[FollowRanking.normalized(result.title)] = other.name }
        }
        let list = FollowRanking.list(app, read: read, elsewhere: elsewhere)
        lists[app] = list
        selected[app] = Set(list.shortlist.map(\.feedUrl))
        phases[app] = .ready
    }

    func toggle(_ feedUrl: String, in app: FollowApp) {
        if selected[app]?.remove(feedUrl) == nil { selected[app, default: []].insert(feedUrl) }
    }

    func expand(_ app: FollowApp) {
        expanded.insert(app)
    }

    /// Starts adding what is turned on and not in the library, a little apart, since each add reads its source's page.
    func add(_ app: FollowApp, into model: AppModel) {
        let urls = (selected[app] ?? []).filter { !model.hasSource(feedUrl: $0) }
        let ordered = (lists[app]?.ranked ?? []).map(\.feedUrl).filter(urls.contains)
        guard !ordered.isEmpty else { return }
        added[app, default: 0] += ordered.count
        let inFolder = usesAppFolder[app] ?? true
        Task {
            let folderID = inFolder ? await folderID(for: app, in: model) : nil
            for url in ordered {
                model.beginAddSource(url: url, folderID: folderID)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func folderID(for app: FollowApp, in model: AppModel) async -> Int64? {
        if let existing = model.folders.first(where: { $0.title.lowercased() == app.name.lowercased() }) { return existing.id }
        return try? await model.createFolder(title: app.name).id
    }
}
