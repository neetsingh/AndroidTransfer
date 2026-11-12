import AppKit
import SwiftUI
import TransferCore

@main
struct AndroidTransferApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = BrowserModel()
    private var window: NSWindow?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let clearCacheItem = appMenu.addItem(withTitle: "Clear Cache", action: #selector(clearCache), keyEquivalent: "")
        clearCacheItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Android Transfer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        menu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        addItem(to: editMenu, "Select All", #selector(selectAll), "a")
        addItem(to: editMenu, "Deselect All", #selector(deselectAll), "a", [.command, .option])
        editMenu.addItem(.separator())
        addItem(to: editMenu, "Download", #selector(download), "s")
        addItem(to: editMenu, "Delete…", #selector(deleteSelection), "\u{8}")
        editMenuItem.submenu = editMenu
        NSApplication.shared.mainMenu = menu

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Android Transfer"
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        self.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.handleKey(event) else { return event }
            return nil
        }
        showWindow()
    }

    private func addItem(
        to menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
    }

    @objc private func selectAll() { model.selectAll() }
    @objc private func deselectAll() { model.deselectAll() }
    @objc private func download() { model.downloadSelected() }
    @objc private func deleteSelection() { model.deleteSelected() }

    /// Arrow keys move the selection (Shift extends it), Return opens, Escape deselects, Delete deletes.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.deviceName != nil, !model.isBusy, !model.isLoadingFolder else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let move: SelectionMove?
        switch event.keyCode {
        case 123: move = .left
        case 124: move = .right
        case 125: move = command ? nil : .down
        case 126: move = command ? nil : .up
        case 115: move = .first // Home
        case 119: move = .last // End
        case 116: move = .pageUp
        case 121: move = .pageDown
        default: move = nil
        }
        if let move, !flags.contains(.control), !flags.contains(.option) {
            if command, move == .left || move == .right { return false }
            model.moveSelection(move, extend: shift)
            return true
        }
        switch event.keyCode {
        case 126 where command: // ⌘↑ goes to the enclosing folder, like Finder
            model.goBack()
            return true
        case 125 where command, 36, 76: // ⌘↓, Return, Enter
            model.activateCursor()
            return true
        case 53: // Escape
            model.deselectAll()
            return true
        case 51 where !command, 117: // Delete, Forward Delete (⌘⌫ is handled by the Edit menu)
            model.deleteSelected()
            return true
        default:
            return false
        }
    }

    @objc private func clearCache() {
        model.clearCache()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct ContentView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.deviceName ?? "Android Transfer").font(.headline)
                    Text(model.deviceName == nil ? "USB file transfer for macOS" : "Connected via USB")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect / Reconnect", action: model.connect)
                    .disabled(model.isBusy)
            }
            .padding()
            Divider()
            if model.deviceName == nil {
                VStack(spacing: 16) {
                    Spacer()
                    if model.isLoadingFolder {
                        loadingIndicator
                    } else {
                        Image(systemName: "cable.connector").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text("Connect your Android device").font(.title2.bold())
                        Text("Unlock your phone, connect it with a USB data cable, then choose File transfer / MTP in its USB settings.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                        Button("Connect", action: model.connect).controlSize(.large).disabled(model.isBusy)
                    }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                browser
            }
            Divider()
            HStack {
                if (model.isBusy && model.progress == nil) || model.isRevalidating {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let progress = model.progress {
                    ProgressView(value: progress).frame(width: 150)
                    Text(progress, format: .percent).font(.caption.monospacedDigit())
                }
            }.padding(.horizontal).padding(.vertical, 10)
        }
        .alert("Android Transfer", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.storages) { storage in
                        Button(storage.name) { model.chooseStorage(storage) }
                    }
                } label: {
                    Label(model.storage?.name ?? "Storage", systemImage: "externaldrive")
                }.disabled(model.isBusy)
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }.help("Back").disabled(model.folders.isEmpty || model.isBusy)
                Text((["Storage"] + model.folders.map(\.name)).joined(separator: " / "))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").disabled(model.isBusy)
                Picker("View", selection: Binding(
                    get: { model.viewMode },
                    set: { model.setViewMode($0) }
                )) {
                    Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                    Label("Gallery", systemImage: "square.grid.2x2").tag(BrowserViewMode.gallery)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .disabled(model.isBusy)
                Menu {
                    Picker("Sort by", selection: Binding(
                        get: { model.sort },
                        set: { model.setSort($0) }
                    )) {
                        ForEach(FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .fixedSize()
                .help("Sort by name or date and time (currently \(model.sort.rawValue))")
                .disabled(model.isBusy)
                Menu {
                    Picker("Group by", selection: Binding(
                        get: { model.grouping },
                        set: { model.setGrouping($0) }
                    )) {
                        Label("No Grouping", systemImage: "square.stack").tag(FileGrouping.none)
                        Label("Date", systemImage: "calendar").tag(FileGrouping.date)
                        Label("Location", systemImage: "mappin.and.ellipse").tag(FileGrouping.location)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Group", systemImage: "square.grid.3x1.below.line.grid.1x2")
                }
                .fixedSize()
                .help("Group files by date, or photos by where they were taken")
                .disabled(model.isBusy)
                if !model.selection.isEmpty {
                    Text("\(model.selection.count) selected")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Select All", action: model.selectAll)
                    .disabled(model.isBusy || model.files.isEmpty)
                Button("Delete", action: model.deleteSelected)
                    .disabled(model.isBusy || model.selectedFiles.isEmpty)
                Button("Download", action: model.downloadSelected)
                    .disabled(model.isBusy || !model.canDownload)
            }.padding()
            Divider()
            if let scan = model.locationScan, !model.isLoadingFolder {
                scanBar("location.magnifyingglass", "Finding photo locations", scan)
            }
            if let scan = model.previewScan, !model.isLoadingFolder, model.viewMode == .gallery {
                scanBar("photo.stack", "Creating previews", scan)
            }
            if model.isLoadingFolder {
                Spacer()
                loadingIndicator
                Spacer()
            } else if model.viewMode == .gallery {
                gallery
            } else {
                fileList
            }
            if model.files.isEmpty && !model.isBusy && model.status == "0 items" {
                Text("This folder is empty.").foregroundStyle(.secondary).padding()
            }
        }
    }

    private func scanBar(_ symbol: String, _ title: String, _ scan: (completed: Int, total: Int)) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text("\(title): \(scan.completed) of \(scan.total)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: Double(scan.completed), total: Double(max(scan.total, 1)))
                    .frame(maxWidth: 220)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6)
            Divider()
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            Text(model.status).font(.headline)
            ProgressView().progressViewStyle(.linear).frame(width: 220)
            Text("This can take a moment for large folders.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.groups) { group in
                    if group.title.isEmpty {
                        ForEach(group.files) { listRow($0) }
                    } else {
                        Section {
                            ForEach(group.files) { listRow($0) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            }
            .onChange(of: model.scrollTarget) { target in
                if let target { proxy.scrollTo(target) }
            }
        }
        .disabled(model.isBusy)
    }

    /// Finder-style clicks: plain selects one, ⌘ or Control toggles, Shift selects a range (⌘-Shift adds it).
    private func handleClick(_ file: DeviceFile) {
        let flags = NSEvent.modifierFlags
        model.click(file, kind: SelectionClick(
            command: flags.contains(.command), control: flags.contains(.control), shift: flags.contains(.shift)
        ))
    }

    private func isCursor(_ file: DeviceFile) -> Bool {
        model.selectionState.cursor == file.id && model.selection.count > 1
    }

    private func listRow(_ file: DeviceFile) -> some View {
        HStack {
            selectionButton(file)
            Image(systemName: file.isFolder ? "folder.fill" : "doc")
                .foregroundStyle(file.isFolder ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            Text(file.name).lineLimit(1)
            Spacer()
            Text(dateText(file.modifiedAt))
                .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                .frame(width: 170, alignment: .trailing)
                .help(dateHelp(file.modifiedAt))
            Text(file.isFolder ? "" : ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file))
                .foregroundStyle(.secondary).font(.caption)
                .frame(width: 80, alignment: .trailing)
            if file.isFolder {
                Button("Open") { model.open(file) }.buttonStyle(.borderless)
            }
        }
        .id(file.id)
        .contentShape(Rectangle())
        .onTapGesture { handleClick(file) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.activate(file) })
        .listRowBackground(
            RoundedRectangle(cornerRadius: 5)
                .fill(model.selection.contains(file.id) ? Color.accentColor.opacity(0.22) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isCursor(file) ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .padding(.horizontal, 6)
        )
        .accessibilityAddTraits(model.selection.contains(file.id) ? .isSelected : [])
    }

    private func groupHeader(_ group: FileGroup) -> some View {
        let state = model.groupSelection(group)
        let selectedCount = group.files.filter { model.selection.contains($0.id) }.count
        return HStack(spacing: 6) {
            Button {
                // ⌥-click selects only this group, replacing the rest of the selection.
                model.toggleGroup(group, exclusive: NSEvent.modifierFlags.contains(.option))
            } label: {
                Image(systemName: state == .all ? "checkmark.circle.fill" : state == .some ? "minus.circle.fill" : "circle")
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(state == .all ? "Deselect this group" : "Select this group (⌥-click to select only this group)")
            .accessibilityLabel("\(state == .all ? "Deselect" : "Select") group \(group.title)")
            Image(systemName: groupSymbol(group))
            Text(group.title).font(.headline)
            Text(selectedCount > 0 ? "\(selectedCount) of \(group.files.count) selected" : "\(group.files.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Select Group") { if state != .all { model.toggleGroup(group) } }
                .disabled(state == .all)
            Button("Select Only This Group") { model.toggleGroup(group, exclusive: true) }
            Button("Deselect Group") { model.deselectGroup(group) }
                .disabled(state == .none)
        }
    }

    private func groupSymbol(_ group: FileGroup) -> String {
        if group.id == "folders" { return "folder" }
        switch model.grouping {
        case .date: return group.id == "no-date" ? "calendar.badge.exclamationmark" : "calendar"
        case .location:
            if group.id == "pending-location" { return "location.magnifyingglass" }
            return group.id == "no-location" ? "location.slash" : "mappin.and.ellipse"
        case .none: return "square.stack"
        }
    }

    private var gallery: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 135, maximum: 180), spacing: 16)],
                spacing: 16,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(model.groups) { group in
                    if group.title.isEmpty {
                        ForEach(group.files) { galleryCell($0) }
                    } else {
                        Section {
                            ForEach(group.files) { galleryCell($0) }
                        } header: {
                            groupHeader(group)
                                .padding(.vertical, 6)
                                .background(.bar)
                        }
                    }
                }
            }.padding()
        }
        .onChange(of: model.scrollTarget) { target in
            if let target { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(target) } }
        }
        }
        .onAppear { updateColumns(geometry.size.width) }
        .onChange(of: geometry.size.width) { updateColumns($0) }
        }
        .disabled(model.isBusy)
    }

    private func updateColumns(_ width: CGFloat) {
        model.galleryColumns = SelectionNavigator.adaptiveColumns(
            width: Double(width), minimum: 135, spacing: 16, padding: 16
        )
    }

    private func galleryCell(_ file: DeviceFile) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                if let image = model.thumbnails[file.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: symbol(for: file))
                        .font(.system(size: 38))
                        .foregroundStyle(file.isFolder ? Color.accentColor : Color.secondary)
                }
                if file.mediaKind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                VStack {
                    HStack {
                        selectionButton(file)
                        Spacer()
                    }
                    Spacer()
                }.padding(6)
            }
            .frame(height: 125)
            Text(file.name).font(.caption).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
            Text(dateText(file.modifiedAt))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .help(dateHelp(file.modifiedAt))
        }
        .padding(6)
        .background(model.selection.contains(file.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCursor(file) ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { handleClick(file) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.activate(file) })
        .id(file.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityAddTraits(model.selection.contains(file.id) ? .isSelected : [])
    }

    private func selectionButton(_ file: DeviceFile) -> some View {
        Button {
            model.toggleSelection(file)
        } label: {
            Image(systemName: model.selection.contains(file.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.selection.contains(file.id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(model.selection.contains(file.id) ? "Deselect" : "Select") \(file.name)")
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private func dateHelp(_ date: Date?) -> String {
        date.map { "Modified \($0.formatted(date: .complete, time: .standard))" } ?? "Modification date unavailable"
    }

    private func symbol(for file: DeviceFile) -> String {
        if file.isFolder { return "folder.fill" }
        switch file.mediaKind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case nil: return "doc"
        }
    }
}
