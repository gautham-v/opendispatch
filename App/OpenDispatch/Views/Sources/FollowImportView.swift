import OpenDispatchCore
import SwiftUI

/// "Bring who you follow": an app's list read on the device, reviewed with a shortlist turned on, and added. On the Mac it has the
/// two panes of the Add sources sheet, with the apps in the column; on iPhone and iPad one column, starting on the list of apps when
/// no app was picked. The store (`model.followImport`) keeps each list, so this can close and open again without reading it twice.
struct FollowImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn: SignInTarget?
    @State private var signingInApp: FollowApp?

    private var store: FollowImportStore { model.followImport }

    var body: some View {
        content
            .onChange(of: store.pendingSignIn, initial: true) { _, account in
                guard let account else { return }
                store.pendingSignIn = nil
                signingInApp = store.app
                signingIn = .account(account)
            }
            .sheet(item: $signingIn, onDismiss: {
                Task {
                    await model.didCloseSignIn()
                    if let signingInApp { await store.signInClosed(signingInApp) }
                }
            }) { target in
                WebSignInView(target: target)
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            column
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .font(OFFont.ui(14.5))
                        .foregroundStyle(.ofAccent)
                        .keyboardShortcut(.cancelAction)
                        .padding(16)
                }
        }
        .frame(width: 780, height: 600)
        .background(Color.ofSurface)
        #else
        NavigationStack {
            detail
                .background(Color.ofSurface)
                .navigationTitle(store.app == nil ? "Bring who you follow" : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        #endif
    }

    #if os(macOS)
    private var column: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bring who you follow")
                .font(OFFont.ui(17, .semibold))
                .foregroundStyle(.ofInk)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            ForEach(FollowApp.allCases) { app in
                Button {
                    Task { await store.select(app) }
                } label: {
                    HStack(spacing: 9) {
                        SourceBadge(host: app.host, title: app.name, size: 16)
                        Text(app.name)
                            .font(OFFont.ui(14.5))
                            .foregroundStyle(.ofInk)
                        Spacer(minLength: 4)
                        if let added = store.added[app] {
                            Text(added, format: .number)
                                .font(OFFont.ui(13))
                                .monospacedDigit()
                                .foregroundStyle(.ofMuted)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(store.app == app ? Color.ofSelection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 20)
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.ofGround)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.ofHairline).frame(width: 1) }
    }
    #endif

    @ViewBuilder private var detail: some View {
        if let app = store.app {
            FollowAppDetail(app: app) { dismiss() }
                .id(app)
        } else {
            #if os(macOS)
            Text("Pick an app to see who you follow there.")
                .font(OFFont.ui(14.5))
                .foregroundStyle(.ofMuted)
            #else
            List(FollowApp.allCases) { app in
                Button {
                    Task { await store.select(app) }
                } label: {
                    HStack(spacing: 12) {
                        SourceBadge(host: app.host, title: app.name, size: 24)
                        Text(app.name)
                            .font(OFFont.ui(14.5))
                            .foregroundStyle(.ofInk)
                        Spacer(minLength: 4)
                        if store.added[app] != nil {
                            OFIcon.check.image.foregroundStyle(.ofAccent)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #endif
        }
    }
}

/// One app, whichever step its list is on.
private struct FollowAppDetail: View {
    let app: FollowApp
    let close: () -> Void
    @Environment(AppModel.self) private var model

    private var store: FollowImportStore { model.followImport }

    var body: some View {
        switch store.phase(app) {
        case .idle:
            Color.clear
        case .needsHandle:
            FollowHandleForm(app: app)
        case .needsGoAhead:
            goAhead
        case .reading(let found):
            reading(found)
        case .ready:
            if let list = store.lists[app] { FollowReview(list: list, close: close) }
        case .failed(let message):
            failure(message)
        }
    }

    private var goAhead: some View {
        FollowStep(app: app, title: "Bring who you follow on \(app.name)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenDispatch signs in on this device and reads your list once. It never posts or follows anyone.")
                if app == .instagram {
                    Text("Instagram doesn\u{2019}t offer a way to share this list, so it may ask you to confirm it\u{2019}s you. Only the first 200 are read, slowly, and 12 start turned on.")
                }
            }
        } action: {
            FollowPrimaryButton(title: model.accounts.isSignedIn(app.account ?? .x) ? "Read My List" : "Sign In\u{2026}") {
                Task { await store.goAhead(app) }
            }
        }
    }

    private func reading(_ found: Int) -> some View {
        FollowStep(app: app, title: "Reading your \(app.name) list") {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(found == 0 ? "Getting started\u{2026}" : "Found \(found.formatted(.number)) so far")
                    .monospacedDigit()
                Text("This stays on this device. Nothing is posted or followed.")
            }
        } action: {
            EmptyView()
        }
    }

    private func failure(_ message: String) -> some View {
        FollowStep(app: app, title: "That didn\u{2019}t work") {
            Text(message)
        } action: {
            FollowPrimaryButton(title: "Try Again") {
                Task { await store.tryAgain(app) }
            }
        }
    }
}

/// A step before the list: the app's icon, a title, a few lines and a button.
private struct FollowStep<Message: View, Action: View>: View {
    let app: FollowApp
    let title: String
    @ViewBuilder let message: Message
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourceBadge(host: app.host, title: app.name, size: 40)
            Text(title)
                .font(OFFont.ui(17, .semibold))
                .foregroundStyle(.ofInk)
            message
                .font(OFFont.ui(14))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
            action
                .padding(.top, 8)
        }
        .frame(maxWidth: 380, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct FollowHandleForm: View {
    let app: FollowApp
    @Environment(AppModel.self) private var model
    @State private var handle = ""
    @FocusState private var focused: Bool

    var body: some View {
        FollowStep(app: app, title: "Your \(app.name) handle") {
            VStack(alignment: .leading, spacing: 8) {
                TextField(app.handlePlaceholder, text: $handle)
                    .textFieldStyle(.plain)
                    .font(OFFont.ui(14.5))
                    .foregroundStyle(.ofInk)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ofGround))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(focused ? Color.ofAccent : Color.ofBorder, lineWidth: 1))
                    .onSubmit(submit)
                    .accessibilityLabel("\(app.name) handle")
                Text(app.handleHint)
            }
        } action: {
            FollowPrimaryButton(title: "Find Who I Follow", action: submit)
                .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.followImport.submit(handle: handle, for: app)
    }
}

private struct FollowPrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OFFont.ui(14.5, .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ofAccent.opacity(isEnabled ? 1 : 0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The list: the shortlist turned on, the rest behind one tap, and what was left out.
private struct FollowReview: View {
    let list: FollowList
    let close: () -> Void
    @Environment(AppModel.self) private var model

    private var store: FollowImportStore { model.followImport }
    private var app: FollowApp { list.app }
    private var addCount: Int { (store.selected[app] ?? []).filter { !model.hasSource(feedUrl: $0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.listTitle)
                    .font(OFFont.ui(17, .semibold))
                    .foregroundStyle(.ofInk)
                Text(FollowRanking.summary(list))
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list.shortlist) { row($0) }
                    if store.expanded.contains(app) {
                        ForEach(list.rest) { row($0) }
                    } else if !list.rest.isEmpty {
                        Rectangle().fill(Color.ofHairline).frame(height: 1)
                        Button("Show \(list.rest.count.formatted(.number)) More") { store.expand(app) }
                            .buttonStyle(.plain)
                            .font(OFFont.ui(13.5))
                            .foregroundStyle(.ofAccent)
                            .frame(minHeight: 40)
                    }
                    if list.leftOut > 0 {
                        Rectangle().fill(Color.ofHairline).frame(height: 1)
                        Text("Left out: \(list.leftOut.formatted(.number)) private or under 1K followers")
                            .font(OFFont.ui(12.5))
                            .foregroundStyle(.ofMuted)
                            .padding(.vertical, 11)
                    }
                }
                .padding(.horizontal, 18)
            }
            .overlayScrollers()

            Rectangle().fill(Color.ofHairline).frame(height: 1)
            footer
        }
    }

    private func row(_ result: SourceSearchResult) -> some View {
        let inLibrary = model.hasSource(feedUrl: result.feedUrl)
        let on = inLibrary || store.selected[app]?.contains(result.feedUrl) == true
        return VStack(spacing: 0) {
            Rectangle().fill(Color.ofHairline).frame(height: 1)
            Button {
                store.toggle(result.feedUrl, in: app)
            } label: {
                HStack(spacing: 10) {
                    avatar(result)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                            .font(OFFont.ui(14.5, .medium))
                            .foregroundStyle(.ofInk)
                            .lineLimit(1)
                        Text(detail(result, inLibrary: inLibrary))
                            .font(OFFont.ui(13))
                            .foregroundStyle(.ofMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(on ? Color.ofAccent : Color.ofFaint)
                        .opacity(inLibrary ? 0.45 : 1)
                }
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(inLibrary)
            .accessibilityValue(inLibrary ? "In your library" : on ? "On" : "Off")
        }
    }

    private func detail(_ result: SourceSearchResult, inLibrary: Bool) -> String {
        var parts: [String] = []
        if let handle = result.handle { parts.append(result.place == .reddit ? handle : "@" + handle) }
        if inLibrary {
            parts.append("In your library")
        } else if let other = list.alsoOn[result.feedUrl] {
            parts.append("Also on \(other)")
        } else if let audience = result.audience {
            parts.append(audience)
        }
        if parts.isEmpty { parts.append(result.subtitle) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private func avatar(_ result: SourceSearchResult) -> some View {
        if let image = result.imageUrl, let url = URL(string: image) {
            CachedAsyncImage(url: url, maxPixelSize: 64) { $0.resizable().scaledToFill() } placeholder: { _ in Color.ofCode }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            SourceBadge(host: URLHost.host(of: result.siteUrl ?? result.feedUrl), title: result.title, size: 30)
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Add to")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                Spacer()
                Menu {
                    Picker("Add to", selection: Binding(
                        get: { store.usesAppFolder[app] ?? true },
                        set: { store.usesAppFolder[app] = $0 }
                    )) {
                        Text("\(app.name) Folder").tag(true)
                        Text("No Folder").tag(false)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.usesAppFolder[app] ?? true ? "\(app.name) Folder" : "No Folder")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium))
                    }
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(.ofInk)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Add to")
            }
            FollowPrimaryButton(title: addCount == 1 ? "Add 1" : "Add \(addCount.formatted(.number))") {
                store.add(app, into: model)
                close()
            }
            .disabled(addCount == 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

/// The row of apps on the Start here board. One tap goes to that app.
struct FollowAppTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: FollowApp.allCases.count), spacing: 6) {
            ForEach(FollowApp.allCases) { app in
                FollowAppTile(app: app, isAdded: model.followImport.added[app] != nil) {
                    model.beginFollowImport(app)
                }
            }
        }
    }
}

private struct FollowAppTile: View {
    let app: FollowApp
    let isAdded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                SourceBadge(host: app.host, title: app.name, size: 22)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.ofHover : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.ofBorder, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if isAdded {
                            OFIcon.check.image
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color.ofAccent))
                                .offset(x: 3, y: -3)
                        }
                    }
                Text(app.name)
                    .font(OFFont.ui(10.5))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isAdded ? "\(app.name), added. Bring more from \(app.name)" : "Bring who you follow on \(app.name)")
    }
}
