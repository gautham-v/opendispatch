import OpenDispatchCore
import SwiftUI

/// Integrations pane: one line per thing, with the explanations behind an info button. Connected lists the apps signed in to or
/// read by handle, each with Bring In and a menu to sign out; Add an app has a tile for each of the others and for OPML. Send to has
/// Readwise Reader, the webhook and Copy as Markdown, each opening its own form in place (the token never comes back from the
/// Keychain: the field starts empty and the row shows its hint, "Token …abcd"). Last, paywalled articles: what the lists do with sites
/// you aren't signed in to, the sites known to have a paywall, and a field to sign in to one by its domain.
struct SettingsIntegrationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsCompact) private var compact

    private enum Field: Hashable { case token, webhook, copyPrompt, newSite }
    private enum SendRow: Hashable { case readwise, webhook, copy }
    private enum TestState: Equatable {
        case running
        case ok(String)
        case error(String)
    }

    @State private var token = ""
    /// nil = untouched (the field shows the saved URL).
    @State private var webhookDraft: String?
    /// nil = untouched (the field shows the saved prompt).
    @State private var promptDraft: String?
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var tests: [SendTarget: TestState] = [:]
    @State private var savedFlash: Task<Void, Never>?
    /// The sign-in sheet opened from here (Settings is itself a sheet on iOS, so RootView's can't show over it).
    @State private var signingIn: SignInTarget?
    /// The sheet for bringing who you follow in from another app.
    @State private var importingFollows = false
    @State private var importingOPML = false
    /// The send target whose form is open.
    @State private var openSend: SendRow?
    /// The domain typed to add a site.
    @State private var newSite = ""
    @FocusState private var focus: Field?

    private var state: IntegrationsState { model.integrations }
    private var savedURL: String { state.webhookURL ?? "" }
    private var webhook: String { webhookDraft ?? savedURL }
    private var dirty: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || webhook.trimmingCharacters(in: .whitespacesAndNewlines) != savedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            connectedSection
            addAppSection
            sendSection
            paywallSection
        }
        .sheet(item: $signingIn, onDismiss: { Task { await model.didCloseSignIn() } }) { target in
            WebSignInView(target: target, onDone: { if case .site(let site, _) = target { model.accounts.signIn(site: site) } })
        }
        .sheet(isPresented: $importingFollows) {
            FollowImportView().environment(model)
        }
        .opmlImporter(isPresented: $importingOPML)
        .task { await model.accounts.refresh() }
        .onChange(of: focus) { old, _ in if old == .copyPrompt { commitPrompt() } }
        .onDisappear {
            savedFlash?.cancel()
            commitPrompt()
        }
    }

    // MARK: Apps

    private func isConnected(_ app: FollowApp) -> Bool {
        if let account = app.account { return model.accounts.isSignedIn(account) }
        return model.followImport.savedHandle(app) != nil
    }

    private func bringIn(_ app: FollowApp) {
        importingFollows = true
        Task { await model.followImport.select(app) }
    }

    private var connectedSection: some View {
        let apps = FollowApp.allCases.filter(isConnected)
        return IntegrationsSection("Connected", info: "OpenDispatch keeps its own sign-ins on this device; it can\u{2019}t use your browser\u{2019}s. Posts and replies are read only when you search or open them, and Instagram accounts you add are read at each refresh. It never posts or follows anyone.") {
            if apps.isEmpty {
                IntegrationRow(title: "Nothing yet. Pick an app below.", muted: true) { EmptyView() } trailing: { EmptyView() }
            }
            ForEach(apps) { app in
                IntegrationRow(title: app.name, detail: model.followImport.savedHandle(app).map { "@" + $0 }) {
                    SourceBadge(host: app.host, title: app.name, size: 24)
                } trailing: {
                    Button("Bring In") { bringIn(app) }
                        .buttonStyle(SettingsSmallButtonStyle())
                        .accessibilityLabel("Bring in who you follow on \(app.name)")
                    Menu {
                        if let account = app.account {
                            Button("Sign Out") {
                                model.followImport.forget(app)
                                Task { await model.accounts.signOut(account) }
                            }
                        } else {
                            Button("Forget Handle") { model.followImport.forget(app) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(.ofMuted)
                            .frame(width: compact ? 36 : 26, height: compact ? 40 : 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More for \(app.name)")
                }
            }
        }
    }

    private var addAppSection: some View {
        let apps = FollowApp.allCases.filter { !isConnected($0) }
        return VStack(alignment: .leading, spacing: 0) {
            IntegrationsHeader(title: "Add an app")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 10) {
                ForEach(apps) { app in
                    FollowTile(title: app.name, accessibility: "\(app.name). \(app.purpose)") {
                        if let account = app.account { signingIn = .account(account) } else { bringIn(app) }
                    } icon: {
                        SourceBadge(host: app.host, title: app.name, size: 22)
                    }
                    .help(app.purpose)
                }
                FollowTile(title: "OPML", accessibility: "Import from another reader or a podcast app, with an OPML file") {
                    importingOPML = true
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17))
                        .foregroundStyle(.ofMuted)
                }
                .help("Import from another reader or a podcast app, with an OPML file.")
            }
            .padding(.horizontal, compact ? 20 : 0)
            .padding(.bottom, 22)
        }
    }

    // MARK: Send to

    private var sendSection: some View {
        IntegrationsSection("Send to", info: "Where the reader sends items. Stored on this device; the Readwise token is kept in the Keychain.") {
            sendRow(.readwise, title: "Readwise Reader", detail: state.readwiseConfigured ? "Token \(state.readwiseTokenHint ?? "saved")" : nil,
                    isSetUp: state.readwiseConfigured) {
                SourceBadge(host: "readwise.io", title: "Readwise", size: 24)
            }
            if openSend == .readwise {
                readwiseForm
                if state.readwiseConfigured { highlightsRow }
                saveRow
            }
            sendRow(.webhook, title: "Webhook", detail: state.webhookConfigured ? "On" : nil, isSetUp: state.webhookConfigured) {
                sendIcon("arrow.up.forward")
            }
            if openSend == .webhook {
                webhookForm
                saveRow
            }
            sendRow(.copy, title: "Copy as Markdown", detail: model.settings.copyPrompt.isEmpty ? nil : model.settings.copyPrompt,
                    isSetUp: !model.settings.copyPrompt.isEmpty) {
                sendIcon("doc.on.clipboard")
            }
            if openSend == .copy { copyForm }
        }
    }

    private func sendIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.ofMuted)
            .frame(width: 24, height: 24)
            .background(Color.ofSettingsInset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func sendRow<Icon: View>(_ row: SendRow, title: String, detail: String?, isSetUp: Bool, @ViewBuilder icon: @escaping () -> Icon) -> some View {
        IntegrationRow(title: title, detail: detail, icon: icon) {
            Button(openSend == row ? "Close" : isSetUp ? "Edit\u{2026}" : "Set Up\u{2026}") {
                if openSend == .copy { commitPrompt() }
                openSend = openSend == row ? nil : row
            }
            .buttonStyle(SettingsSmallButtonStyle(quiet: openSend == row))
            .accessibilityLabel(openSend == row ? "Close \(title)" : "Set up \(title)")
        }
    }

    private var readwiseForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Access token from ")
                Link("readwise.io/access_token", destination: Self.readwiseTokenURL)
                    .foregroundStyle(.ofAccent)
                Text(state.readwiseConfigured ? ". Paste a new one to replace it." : ".")
            }
            .font(OFFont.ui(compact ? 13.5 : 12))
            .foregroundStyle(.ofMuted)
            .lineLimit(2)

            SecureField(
                state.readwiseConfigured ? "Saved (\(state.readwiseTokenHint ?? "\u{2026}"))" : "Paste your access token",
                text: $token
            )
            .focused($focus, equals: .token)
            .settingsFieldChrome(focused: focus == .token)
            .textContentType(.password)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { Task { await save() } }
            .padding(.top, 6)
            .accessibilityLabel("Readwise Reader access token")

            if state.readwiseConfigured { actions(.readwise, testLabel: "Check token") }
        }
        .padding(.vertical, 12)
    }

    private var highlightsRow: some View {
        SettingsRow(label: "Send highlights to Readwise", hint: "Highlights and notes you make on this device") {
            Toggle("Send highlights to Readwise", isOn: Binding(
                get: { model.settings.sendHighlightsToReadwise },
                set: { model.settings.sendHighlightsToReadwise = $0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.ofOK)
                #if os(macOS)
                .controlSize(.small)
                #endif
        }
    }

    private var webhookForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Each sent item is POSTed as JSON: id, url, title, author, published_at, summary, source.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/hooks/opendispatch", text: Binding(
                get: { webhook },
                set: { value in
                    // A result for the saved URL no longer describes what the field shows.
                    if value != webhook { tests[.webhook] = nil }
                    webhookDraft = value
                }
            ))
            .focused($focus, equals: .webhook)
            .settingsFieldChrome(focused: focus == .webhook)
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { Task { await save() } }
            .padding(.top, 6)
            .accessibilityLabel("Webhook URL")

            if state.webhookConfigured { actions(.webhook, testLabel: "Send a test") }
        }
        .padding(.vertical, 12)
    }

    private var saveRow: some View {
        HStack(spacing: 12) {
            if let error {
                Text(error)
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if saved {
                Text("Saved")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofOK)
                    .transition(.opacity)
            }
            Button(saving ? "Saving\u{2026}" : "Save") { Task { await save() } }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(!dirty || saving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.15), value: saved)
    }

    private var copyForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Added above the copied text, for when you always ask your AI the same thing.")
                .font(OFFont.ui(compact ? 13.5 : 12))
                .foregroundStyle(.ofMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Start copied text with", text: Binding(
                get: { promptDraft ?? model.settings.copyPrompt },
                set: { promptDraft = $0 }
            ), prompt: Text("e.g. Summarize this in 5 bullets"))
            .focused($focus, equals: .copyPrompt)
            .settingsFieldChrome(focused: focus == .copyPrompt)
            .onSubmit { commitPrompt() }
        }
        .padding(.vertical, 12)
    }

    // MARK: Paywalls

    private var paywallSection: some View {
        IntegrationsSection("Paywalled articles", info: "Sites you\u{2019}re signed in to always show in full, and the reader opens their articles as you. The list fills in as you read.") {
            SettingsRow(label: "Sites you don\u{2019}t subscribe to", stacked: compact) {
                SettingsSegmented(label: "Paywalled articles", selection: Bindable(model).settings.paywallTreatment,
                                  options: PaywallTreatment.allCases.map { ($0, $0.label) })
            }
            ForEach(paywallSites, id: \.self) { site in
                let on = model.accounts.signedInSites.contains(site)
                IntegrationRow(title: site, detail: siteHint(site, signedIn: on)) {
                    SourceBadge(host: site, title: site, size: 24)
                } trailing: {
                    Button(on ? "Sign Out" : "Sign In\u{2026}") {
                        if on { Task { await model.accounts.signOut(site: site) } } else { signingIn = .opening(site) }
                    }
                    .buttonStyle(SettingsSmallButtonStyle(quiet: on))
                    .accessibilityLabel(on ? "Sign out of \(site)" : "Sign in to \(site)")
                }
            }
            addSiteRow
        }
    }

    /// Sites the book has seen walled an article and the sites signed in to, most walled first.
    private var paywallSites: [String] {
        let sites = model.settings.paywalls.sites
        return Set(sites.keys).union(model.accounts.signedInSites).sorted {
            let a = sites[$0]?.walled ?? 0, b = sites[$1]?.walled ?? 0
            return a != b ? a > b : $0 < $1
        }
    }

    /// "14 paywalled articles · signed in", "· lets some through" when some read in full, "· not asking" once declined.
    private func siteHint(_ site: String, signedIn: Bool) -> String {
        let record = model.settings.paywalls.sites[site]
        var parts: [String] = []
        if let walled = record?.walled, walled > 0 { parts.append("\(walled) paywalled \(walled == 1 ? "article" : "articles")") }
        if signedIn {
            parts.append("signed in")
        } else {
            if (record?.full ?? 0) > 0 { parts.append("lets some through") }
            if record?.declined == true { parts.append("not asking") }
        }
        guard !parts.isEmpty else { return "Paywall" }
        return parts.joined(separator: " \u{00B7} ").prefix(1).uppercased() + parts.joined(separator: " \u{00B7} ").dropFirst()
    }

    /// A field for a site by its domain ("ft.com", or any address on it) and Sign In… to it.
    private var addSiteRow: some View {
        let site = Self.siteKey(newSite)
        return HStack(spacing: 8) {
            TextField("Site", text: $newSite, prompt: Text("Add a site, e.g. ft.com"))
                .focused($focus, equals: .newSite)
                .settingsFieldChrome(focused: focus == .newSite)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { addSite(site) }
                .accessibilityLabel("Site to sign in to")
            Button("Sign In\u{2026}") { addSite(site) }
                .buttonStyle(SettingsSmallButtonStyle())
                .disabled(site == nil)
        }
        .padding(.vertical, 12)
    }

    private func addSite(_ site: String?) {
        guard let site else { return }
        newSite = ""
        signingIn = .opening(site)
    }

    /// The site key a typed domain or address stands for: "https://www.ft.com/x" and "ft.com" are "ft.com". nil for
    /// text that is no domain.
    static func siteKey(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        let site = Paywalls.site(of: t)
        return site.contains(".") ? site : nil
    }

    private func actions(_ target: SendTarget, testLabel: String) -> some View {
        let t = tests[target]
        return HStack(spacing: 8) {
            Button(t == .running ? "Testing…" : testLabel) { Task { await test(target) } }
                .buttonStyle(SettingsSmallButtonStyle())
                .disabled(t == .running)
            Button("Remove") { Task { await remove(target) } }
                .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                .accessibilityLabel("Remove \(target == .readwise ? "Readwise token" : "webhook")")
            switch t {
            case .ok(let message):
                Text(message).font(OFFont.ui(12.5)).foregroundStyle(.ofOK).lineLimit(2)
            case .error(let message):
                Text(message).font(OFFont.ui(12.5)).foregroundStyle(.ofDanger).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            case .running, nil:
                EmptyView()
            }
        }
        .padding(.top, 8)
    }

    // MARK: Actions

    static let readwiseTokenURL = URL(string: "https://readwise.io/access_token") ?? URL(fileURLWithPath: "/")

    private func apply() {
        token = ""
        webhookDraft = nil
        tests = [:]
    }

    /// Stores the prompt field's text (trimmed) in the settings.
    private func commitPrompt() {
        guard let draft = promptDraft else { return }
        promptDraft = nil
        model.settings.copyPrompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard dirty, !saving else { return }
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let newURL = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error = nil
        defer { saving = false }
        do {
            // The web sent both in one PUT; validate the URL first so a bad URL doesn't half-save.
            if newURL != savedURL { try await model.setWebhookURL(newURL.isEmpty ? nil : newURL) }
            if !newToken.isEmpty { try await model.setReadwiseToken(newToken) }
            apply()
            saved = true
            savedFlash?.cancel()
            savedFlash = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled { saved = false }
            }
        } catch {
            self.error = HTTP.message(error)
        }
    }

    private func remove(_ target: SendTarget) async {
        error = nil
        do {
            switch target {
            case .readwise: try await model.setReadwiseToken(nil)
            case .webhook: try await model.setWebhookURL(nil)
            }
            apply()
        } catch {
            self.error = HTTP.message(error)
        }
    }

    private func test(_ target: SendTarget) async {
        tests[target] = .running
        do {
            try await model.testIntegration(target)
            tests[target] = .ok(target == .readwise ? "Token works" : "Test payload delivered")
        } catch {
            tests[target] = .error(HTTP.message(error))
        }
    }
}

/// A section of the pane: a title with its info button, then the card.
private struct IntegrationsSection<Content: View>: View {
    let title: String
    let info: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, info: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.info = info
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrationsHeader(title: title, info: info)
            SettingsCard(content: content)
        }
    }
}

/// A section title, with the explanation behind an info button when it has one.
private struct IntegrationsHeader: View {
    let title: String
    var info: String?
    @Environment(\.settingsCompact) private var compact
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(compact ? OFFont.ui(15, .medium) : OFFont.ui(13, .semibold))
                .foregroundStyle(compact ? Color.ofMuted : Color.ofInk)
                .accessibilityAddTraits(.isHeader)
            if let info {
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: compact ? 15 : 12.5))
                        .foregroundStyle(.ofMuted)
                        .frame(minWidth: compact ? 30 : 18, minHeight: compact ? 30 : 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $showingInfo) {
                    Text(info)
                        .font(OFFont.ui(13))
                        .foregroundStyle(.ofInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(14)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .frame(minHeight: compact ? 30 : 18)
        .padding(.horizontal, compact ? 20 : 4)
        .padding(.bottom, compact ? 4 : 7)
    }
}

/// One line: an icon, a name, a short detail in muted text and the row's controls.
private struct IntegrationRow<Icon: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var muted = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.settingsCompact) private var compact

    var body: some View {
        HStack(spacing: 10) {
            icon()
            Text(title)
                .font(OFFont.ui(compact ? 17 : 14))
                .foregroundStyle(muted ? Color.ofMuted : Color.ofInk)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(OFFont.ui(compact ? 13.5 : 12.5))
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) { trailing() }
                .fixedSize()
        }
        .frame(minHeight: compact ? 54 : 44)
        .settingsTopHairline()
    }
}
