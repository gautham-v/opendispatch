import OpenDispatchCore
import SwiftUI
import UniformTypeIdentifiers

/// Sources pane on the Mac and iPad (the iPhone has `SourcesView`). Search, Add source and OPML sit at the
/// top with one line for the library (count, failures, last refresh), over one card of folders that start
/// closed, so the pane opens as a single screen however many sources there are. Opening a folder shows its
/// sources in single-line rows; the folder picker and Remove show on hover (always on iPad), and a row
/// only gets a second line when it failed, was never fetched, or is being removed.
struct SettingsSourcesPane: View {
    let onAdd: () -> Void
    let onOpen: (Source) -> Void

    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Open folders, by group key. None to start with: the closed list is the point of this pane.
    @State private var openFolders: Set<String> = []
    @State private var confirming: Int64?
    /// Removed optimistically (hidden until the delete fails).
    @State private var removed: Set<Int64> = []
    @State private var errors: [Int64: String] = [:]
    @State private var renaming: Source?
    @State private var renameDraft = ""
    @State private var opmlStatus: SettingsOPMLStatus?

    private struct SourceGroup {
        let key: String
        let label: String
        let sources: [Source]
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                // Relative time in the summary line stays current while the pane is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    summary(now: context.date, proxy: proxy)
                }
                .padding(.top, 8)
                .padding(.bottom, opmlStatus == nil ? 12 : 4)
                if let opmlStatus {
                    Text(opmlStatus.text)
                        .font(OFFont.ui(12))
                        .foregroundStyle(opmlStatus.error ? Color.ofDanger : Color.ofMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                list
            }
        }
        .alert("Rename source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
        }
    }

    // MARK: Top of the pane

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField
            Button(action: onAdd) {
                HStack(spacing: 6) {
                    OFIcon.plus.image.font(.system(size: 13, weight: .medium))
                    Text("Add source")
                }
            }
            .buttonStyle(SettingsPaneButtonStyle(tint: .ofAccent))
            .fixedSize()
            SettingsOPMLMenu(status: $opmlStatus)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            OFIcon.search.image
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.ofMuted)
            TextField("Search sources", text: $query)
                .textFieldStyle(.plain)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofInk)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.ofFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ofCode))
    }

    /// "44 sources · 1 failing · Refreshed 14 min ago". The failing count jumps to the first failing row.
    private func summary(now: Date, proxy: ScrollViewProxy) -> some View {
        let count = allGroups.reduce(0) { $0 + $1.sources.count }
        let failing = allGroups.reduce(0) { $0 + $1.sources.filter { $0.lastError != nil }.count }
        return HStack(spacing: 4) {
            Text("\(count) source\(count == 1 ? "" : "s")")
            if failing > 0 {
                Text("·")
                Button("\(failing) failing") { showFailing(proxy) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.ofDanger)
                    .accessibilityHint("Shows the first source that failed")
            }
            if let refreshed = refreshLabel(now: now) {
                Text("·")
                Text(refreshed)
            }
        }
        .font(OFFont.ui(12))
        .foregroundStyle(.ofMuted)
        .monospacedDigit()
    }

    private func refreshLabel(now: Date) -> String? {
        if model.isRefreshing { return "Refreshing…" }
        return model.lastRefreshAt.map { Self.fetchedLabel($0, now: now).replacingOccurrences(of: "Fetched", with: "Refreshed") }
    }

    /// Opens every folder with a failure and scrolls to the first one, once the rows exist.
    private func showFailing(_ proxy: ScrollViewProxy) {
        query = ""
        let failing = allGroups.filter { $0.sources.contains { $0.lastError != nil } }
        openFolders.formUnion(failing.map(\.key))
        guard let first = failing.first?.sources.first(where: { $0.lastError != nil }) else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(first.id, anchor: .center) }
        }
    }

    // MARK: Folders

    /// Every non-empty folder, then No Folder, without sources just removed.
    private var allGroups: [SourceGroup] {
        var out = model.orderedFolders.map { f in
            SourceGroup(key: "f\(f.id)", label: f.title, sources: model.allSources(inFolder: f.id).filter { !removed.contains($0.id) })
        }
        out.append(SourceGroup(key: "unfiled", label: "No Folder", sources: model.allSources(inFolder: nil).filter { !removed.contains($0.id) }))
        return out.filter { !$0.sources.isEmpty }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `allGroups`, narrowed to the search's matches while there is one.
    private var shownGroups: [SourceGroup] {
        let groups = allGroups
        guard isSearching else { return groups }
        let matches = Set(SourceList.matching(groups.flatMap(\.sources), query: query).map(\.id))
        return groups.compactMap { g in
            let hits = g.sources.filter { matches.contains($0.id) }
            return hits.isEmpty ? nil : SourceGroup(key: g.key, label: g.label, sources: hits)
        }
    }

    @ViewBuilder private var list: some View {
        let groups = shownGroups
        if groups.isEmpty {
            Text(isSearching ? "No sources match" : "No sources yet")
                .font(OFFont.ui(13))
                .foregroundStyle(.ofMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            // With one group or a search there is nothing to tuck away, so the rows just show.
            let collapsible = !isSearching && allGroups.count > 1
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
                    let isOpen = !collapsible || openFolders.contains(group.key)
                    if index > 0 { SettingsHairline() }
                    SettingsSourceFolderRow(
                        label: group.label,
                        sources: group.sources,
                        isOpen: isOpen,
                        collapsible: collapsible
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if openFolders.contains(group.key) { openFolders.remove(group.key) } else { openFolders.insert(group.key) }
                        }
                    }
                    if isOpen {
                        ForEach(group.sources) { source in
                            SettingsHairline().padding(.leading, SettingsSourceRow.leadingInset)
                            row(source).id(source.id)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .settingsPanelChrome()
        }
    }

    private func row(_ s: Source) -> some View {
        SettingsSourceRow(
            source: s,
            removeError: errors[s.id],
            isConfirming: confirming == s.id,
            onOpen: { onOpen(s) },
            onMove: { move(s, to: $0) },
            onAskToRemove: { confirming = s.id },
            onKeep: { confirming = nil },
            onRemove: { Task { await remove(s) } },
            onRename: {
                renameDraft = s.title
                renaming = s
            }
        )
    }

    private func move(_ s: Source, to folderId: Int64?) {
        guard folderId != s.folderId else { return }
        Task { try? await model.moveSource(id: s.id, toFolder: folderId) }
    }

    private func remove(_ s: Source) async {
        confirming = nil
        errors[s.id] = nil
        removed.insert(s.id)
        do {
            try await model.deleteSource(id: s.id)
        } catch QueryError.notFound {
            // Already gone (the web treated 404 as success).
            await model.loadSources()
        } catch {
            removed.remove(s.id)
            errors[s.id] = HTTP.message(error)
        }
    }

    private func commitRename() {
        guard let s = renaming else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty, title != s.title else { return }
        Task { try? await model.renameSource(id: s.id, title: title) }
    }

    // MARK: Labels

    /// " · posts" / " · podcast" / " · scraped page" after the host.
    static func typeSuffix(_ s: Source) -> String {
        if s.type == .post { return " · posts" }
        if s.type == .podcast || s.kind == .podcast { return " · podcast" }
        if s.kind == .page { return " · scraped page" }
        return ""
    }

    /// fetchedLabel: "Never fetched", "Fetched just now", "Fetched 5 min ago", "Fetched 3 hr ago".
    static func fetchedLabel(_ at: Date?, now: Date) -> String {
        guard let at else { return "Never fetched" }
        let rel = RelativeTime.format(at, now: now)
        if rel == "now" { return "Fetched just now" }
        guard let unitChar = rel.last, let n = Int(rel.dropLast()) else { return "Fetched \(rel) ago" }
        let units: [Character: String] = ["m": "min", "h": "hr", "d": "d", "w": "wk", "y": "yr"]
        return "Fetched \(n) \(units[unitChar] ?? String(unitChar)) ago"
    }
}

// MARK: - Rows

/// A folder in the Sources pane's card: chevron, name, any failures, a few of its badges and its count.
private struct SettingsSourceFolderRow: View {
    let label: String
    let sources: [Source]
    let isOpen: Bool
    let collapsible: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    private var failing: Int { sources.filter { $0.lastError != nil }.count }

    var body: some View {
        Button(action: { if collapsible { onToggle() } }) {
            HStack(spacing: 9) {
                OFIcon.chevron.image
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.ofMuted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                    .opacity(collapsible ? 1 : 0)
                Text(label)
                    .font(OFFont.ui(13, .semibold))
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                if failing > 0 {
                    Text("\(failing) failing")
                        .font(OFFont.ui(12, .medium))
                        .foregroundStyle(.ofDanger)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                HStack(spacing: -3) {
                    ForEach(sources.prefix(4)) { s in
                        SourceBadge(source: s, size: 16)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background).padding(-1.5))
                    }
                }
                Text("\(sources.count)")
                    .font(OFFont.ui(13))
                    .monospacedDigit()
                    .foregroundStyle(.ofMuted)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: SettingsSourceRow.folderHeight)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 && collapsible }
        .accessibilityLabel("\(label), \(sources.count) source\(sources.count == 1 ? "" : "s")\(failing > 0 ? ", \(failing) failing" : "")")
        .accessibilityValue(collapsible ? (isOpen ? "Open" : "Closed") : "")
        .accessibilityAddTraits(.isHeader)
    }

    private var background: Color { isHovered ? .ofSelection : .ofSettingsCard }
}

/// A source in an open folder: badge, name and @handle on one line, with the folder picker and Remove
/// on hover (a pointer may never come on iPad, so they stay put there). Host, type and last fetch are in
/// the tooltip; they took a line on every row and said the same thing on each.
private struct SettingsSourceRow: View {
    /// Lines the rows and their hairlines up with the folder's name.
    static let leadingInset: CGFloat = 33
    #if os(iOS)
    static let folderHeight: CGFloat = 48
    private static let minHeight: CGFloat = 44
    private static let nameSize: CGFloat = 14
    #else
    static let folderHeight: CGFloat = 42
    private static let minHeight: CGFloat = 36
    private static let nameSize: CGFloat = 13
    #endif

    let source: Source
    let removeError: String?
    let isConfirming: Bool
    let onOpen: () -> Void
    let onMove: (Int64?) -> Void
    let onAskToRemove: () -> Void
    let onKeep: () -> Void
    let onRemove: () -> Void
    let onRename: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private var showsControls: Bool {
        #if os(iOS)
        true
        #else
        isHovered || isConfirming
        #endif
    }

    var body: some View {
        HStack(spacing: 10) {
            SourceBadge(source: source, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Button(action: onOpen) {
                    HStack(spacing: 5) {
                        Text(source.shortTitle)
                            .foregroundStyle(.ofInk)
                            .layoutPriority(1)
                        if let handle = source.titleHandle {
                            Text("@\(handle)").foregroundStyle(.ofMuted)
                        }
                    }
                    .font(OFFont.ui(Self.nameSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(details(now: Date()))
                .accessibilityLabel(source.title)
                .accessibilityHint("Opens its feed")
                subline
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
                // Nearly clear rather than clear, so they stay reachable by keyboard and VoiceOver and the row
                // doesn't change width on hover.
                .opacity(showsControls ? 1 : 0.001)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(minHeight: Self.minHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Feed", action: onOpen)
            Button("Rename…", action: onRename)
            Divider()
            Button("Remove", role: .destructive, action: onAskToRemove)
        }
    }

    /// Only what a row needs to say for itself: a failure, a first fetch still to come, or what Remove does.
    @ViewBuilder private var subline: some View {
        if let removeError {
            sublineText("Could not remove: \(removeError)", color: .ofDanger)
        } else if isConfirming {
            sublineText("Removes its items, including any you saved.", color: .ofMuted)
        } else if let err = source.lastError {
            sublineText("Error: \(err)", color: .ofDanger).help(err)
        } else if source.lastFetchedAt == nil {
            sublineText("Never fetched", color: .ofMuted)
        }
    }

    private func sublineText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OFFont.ui(12))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func details(now: Date) -> String {
        "\(source.host)\(SettingsSourcesPane.typeSuffix(source)) · \(SettingsSourcesPane.fetchedLabel(source.lastFetchedAt, now: now))"
    }

    @ViewBuilder private var controls: some View {
        if isConfirming {
            HStack(spacing: 6) {
                Button("Keep", action: onKeep)
                    .buttonStyle(SettingsSmallButtonStyle())
                Button("Remove", action: onRemove)
                    .buttonStyle(SettingsSmallButtonStyle(fill: .ofDanger))
                    .accessibilityLabel("Remove \(source.title)")
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack(spacing: 2) {
                if !model.folders.isEmpty { folderPicker }
                Button("Remove", action: onAskToRemove)
                    .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                    .accessibilityLabel("Remove \(source.title)")
            }
        }
    }

    private var folderPicker: some View {
        Menu {
            Picker("Folder", selection: Binding(get: { source.folderId }, set: { onMove($0) })) {
                ForEach(model.orderedFolders) { f in
                    Text(f.title).tag(Int64?.some(f.id))
                }
                Text("No Folder").tag(Int64?.none)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(model.folders.first { $0.id == source.folderId }?.title ?? "No Folder")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(OFFont.ui(12))
            .foregroundStyle(.ofMuted)
            .padding(.horizontal, 6)
            .frame(maxWidth: 120, minHeight: 26)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ofBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Folder for \(source.title)")
    }
}

// MARK: - OPML

/// The OPML file type declared in project.yml (UTImportedTypeDeclarations).
extension UTType {
    static let openDispatchOPML = UTType(importedAs: "org.opml.opml", conformingTo: .xml)
}

/// Export payload for `.fileExporter`.
struct SettingsOPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.openDispatchOPML, .xml]
    static let writableContentTypes: [UTType] = [.openDispatchOPML]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Result line under the OPML buttons (role="status" in the web).
struct SettingsOPMLStatus: Equatable {
    var text: String
    var error: Bool
}

/// Import OPML for a row or button that has no result line beneath it (the phone's Settings and Sources
/// screens): picks the file, imports it, refreshes so the new sources load, and reports the summary in
/// an alert.
private struct SettingsOPMLImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var status: SettingsOPMLStatus?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.openDispatchOPML, .xml]) { result in
                switch result {
                case .success(let url): Task { await importFile(url) }
                case .failure(let error): status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
                }
            }
            .alert("Import OPML", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(status?.text ?? "")
            }
    }

    private func importFile(_ url: URL) async {
        do {
            let r = try await model.importOPML(from: url)
            status = .init(text: SettingsOPMLMenu.summary(r), error: r.added == 0 && !r.errors.isEmpty)
            if r.added > 0 { Task { await model.refresh(force: true) } }
        } catch {
            status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
        }
    }
}

extension View {
    /// Presents the OPML file picker when `isPresented` turns true, then imports the file.
    func opmlImporter(isPresented: Binding<Bool>) -> some View {
        modifier(SettingsOPMLImporter(isPresented: isPresented))
    }
}

/// The … menu at the top of the Sources pane: Import OPML and Export OPML. The result line is shown by the parent.
struct SettingsOPMLMenu: View {
    @Binding var status: SettingsOPMLStatus?
    @Environment(AppModel.self) private var model
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var busy = false
    @State private var exportDoc: SettingsOPMLDocument?

    var body: some View {
        // The file panels hang off the Menu itself: a menu's items are gone once it closes.
        Menu {
            Button(busy ? "Importing…" : "Import OPML…") { isImporting = true }
                .disabled(busy)
            Button("Export OPML…") { Task { await export() } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(.ofInk)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ofCode))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Import or export OPML")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.openDispatchOPML, .xml]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDoc,
            contentType: .openDispatchOPML,
            defaultFilename: String(AppModel.opmlFileName().dropLast(".opml".count))
        ) { result in
            switch result {
            case .success: status = .init(text: "Exported \(model.sources.count) source\(model.sources.count == 1 ? "" : "s").", error: false)
            case .failure(let error): status = .init(text: "Export failed: \(HTTP.message(error))", error: true)
            }
            exportDoc = nil
        }
    }

    private func importFile(_ url: URL) async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            let r = try await model.importOPML(from: url)
            status = .init(text: Self.summary(r), error: r.added == 0 && !r.errors.isEmpty)
        } catch {
            status = .init(text: "Import failed: \(HTTP.message(error))", error: true)
        }
    }

    private func export() async {
        do {
            exportDoc = SettingsOPMLDocument(text: try await model.exportOPML())
            isExporting = true
        } catch {
            status = .init(text: "Export failed: \(HTTP.message(error))", error: true)
        }
    }

    /// "Added 3, skipped 1, 2 new folders, 1 failed. New sources load on the next refresh.", then the
    /// first few failures ("Title: Invalid URL") one per line so a bad entry can be found and fixed.
    static func summary(_ r: OPMLImportResult) -> String {
        var parts = ["Added \(r.added)", "skipped \(r.skipped)"]
        if r.foldersCreated > 0 { parts.append("\(r.foldersCreated) new folder\(r.foldersCreated == 1 ? "" : "s")") }
        if !r.errors.isEmpty { parts.append("\(r.errors.count) failed") }
        var lines = [parts.joined(separator: ", ") + "." + (r.added > 0 ? " New sources load on the next refresh." : "")]
        let shown = 3
        lines += r.errors.prefix(shown)
        if r.errors.count > shown { lines.append("and \(r.errors.count - shown) more") }
        return lines.joined(separator: "\n")
    }
}
