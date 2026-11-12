import AppKit
import Foundation
import TransferCore

enum BrowserViewMode: String, CaseIterable {
    case list = "List"
    case gallery = "Gallery"
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var deviceName: String?
    @Published var storages: [Storage] = []
    @Published var storage: Storage?
    @Published var folders: [Folder] = []
    @Published var files: [DeviceFile] = []
    @Published private(set) var selectionState = SelectionState()
    /// Set when the keyboard moves the cursor, so the view scrolls it into view; clicks don't scroll.
    @Published private(set) var scrollTarget: DeviceFile.ID?
    var galleryColumns = 1
    @Published var isBusy = false
    @Published var status = "Connect an Android device to get started."
    @Published var errorMessage: String?
    @Published var progress: Double?
    @Published var isLoadingFolder = false
    @Published private(set) var isRevalidating = false
    @Published private(set) var viewMode: BrowserViewMode = .list
    @Published private(set) var thumbnails: [DeviceFile.ID: NSImage] = [:]
    @Published private(set) var unavailableThumbnails: Set<DeviceFile.ID> = []
    @Published private(set) var grouping: FileGrouping = .none
    @Published private(set) var sort: FileSort = .nameAscending
    @Published private(set) var locations: [DeviceFile.ID: PhotoLocation] = [:]
    @Published private(set) var locationScan: (completed: Int, total: Int)?
    @Published private(set) var previewScan: (completed: Int, total: Int)?
    /// Recomputed only when its inputs change, so scrolling and redraws don't re-sort large folders.
    @Published private(set) var groups: [FileGroup] = []

    private let service = MTPService()
    private let rootID = UInt32.max
    private var thumbnailTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var revalidationTask: Task<Void, Never>?
    private let placeNamer = PlaceNamer()
    private let mediaCache = MediaCache(directory: MediaCache.defaultDirectory)
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 3000
        return cache
    }()
    /// Folder listings for this connection, keyed by storage and folder path, so revisiting a folder is instant.
    private var listingCache: [String: [DeviceFile]] = [:]
    private var deviceIdentity = ""

    init() {
        let cache = mediaCache
        Task.detached(priority: .background) { await cache.prune(maxBytes: 300 * 1024 * 1024) }
    }

    var selection: Set<DeviceFile.ID> { selectionState.selected }
    var selectedFiles: [DeviceFile] { files.filter { selection.contains($0.id) } }
    /// Items in the order they're displayed, which is what Shift ranges and arrow keys follow.
    private var displayOrder: [DeviceFile.ID] { groups.flatMap { $0.files.map(\.id) } }
    var selectedFile: DeviceFile? { selectedFiles.count == 1 ? selectedFiles.first : nil }
    var canDownload: Bool { selectedFiles.contains { !$0.isFolder } }

    private var listingKey: String {
        "\(storage?.id ?? 0)/" + folders.map { String($0.id) }.joined(separator: "/")
    }

    private func cacheKey(_ file: DeviceFile, storageID: UInt32, path: [String]) -> MediaCacheKey {
        MediaCacheKey(device: deviceIdentity, storageID: storageID, path: path, file: file)
    }

    private func setFiles(_ newFiles: [DeviceFile]) {
        files = newFiles
        regroup()
    }

    private func regroup() {
        groups = FileGrouper.groups(files, by: grouping, locations: locations, sort: sort)
    }

    func connect() {
        guard !isBusy else { return }
        resetThumbnails()
        stopLocationScan()
        stopRevalidation()
        locations = [:]
        listingCache = [:]
        isBusy = true
        isLoadingFolder = true
        status = "Connecting..."
        deviceName = nil
        storages = []
        storage = nil
        setFiles([])
        folders = []
        selectionState.clear()
        Task {
            do {
                let device = try await service.connect()
                deviceName = device.name
                deviceIdentity = device.cacheIdentity
                storages = device.storages
                storage = device.storages.first
                try await load()
            } catch {
                setFiles([])
                status = deviceName == nil ? "Not connected." : "Could not read folder."
                errorMessage = error.localizedDescription
            }
            isLoadingFolder = false
            isBusy = false
            startBackgroundWork()
        }
    }

    func chooseStorage(_ storage: Storage) {
        guard !isBusy else { return }
        self.storage = storage
        folders = []
        navigate()
    }

    func open(_ file: DeviceFile) {
        guard file.isFolder, !isBusy else { return }
        folders.append(Folder(id: file.id, name: file.name))
        navigate()
    }

    func goBack() {
        guard !folders.isEmpty, !isBusy else { return }
        folders.removeLast()
        navigate()
    }

    /// Reloads the folder from the device, ignoring the cached listing.
    func refresh() {
        navigate(force: true)
    }

    private func navigate(force: Bool = false) {
        guard !isBusy, storage != nil else { return }
        resetThumbnails()
        stopLocationScan()
        stopRevalidation()
        selectionState.clear()
        if !force, let cached = listingCache[listingKey] {
            show(cached)
            status = "\(itemCount) · checking for changes..."
            startBackgroundWork()
            revalidate()
            return
        }
        isBusy = true
        isLoadingFolder = true
        setFiles([])
        Task {
            do { try await load() }
            catch {
                setFiles([])
                status = "Could not read folder."
                errorMessage = error.localizedDescription
            }
            isLoadingFolder = false
            isBusy = false
            startBackgroundWork()
        }
    }

    private var itemCount: String { "\(files.count) item\(files.count == 1 ? "" : "s")" }

    private func show(_ listing: [DeviceFile]) {
        setFiles(listing)
        viewMode = listing.contains { $0.mediaKind != nil } ? .gallery : .list
        status = itemCount
    }

    private func load() async throws {
        guard let storage else { return }
        let key = listingKey
        selectionState.clear()
        status = "Reading files..."
        let listing = try await service.list(storageID: storage.id, parentID: folders.last?.id ?? rootID)
        listingCache[key] = listing
        show(listing)
    }

    /// Shows the cached listing immediately, then quietly re-reads the folder and applies any changes.
    private func revalidate() {
        guard let storage else { return }
        let key = listingKey
        let parentID = folders.last?.id ?? rootID
        isRevalidating = true
        revalidationTask = Task { [weak self] in
            let fresh: [DeviceFile]
            do {
                guard let self else { return }
                fresh = try await self.service.list(storageID: storage.id, parentID: parentID)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isRevalidating = false
                if !self.isBusy { self.status = "\(self.itemCount) · showing cached list" }
                NSLog("Could not revalidate folder: %@", error.localizedDescription)
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.isRevalidating = false
            self.revalidationTask = nil
            self.listingCache[key] = fresh
            // A delete or download that started meanwhile will refresh the folder itself.
            guard !self.isBusy, key == self.listingKey else { return }
            if fresh != self.files {
                self.setFiles(fresh)
                self.selectionState.retain(Set(fresh.map(\.id)))
                self.startBackgroundWork()
            }
            self.status = self.itemCount
        }
    }

    private func stopRevalidation() {
        revalidationTask?.cancel()
        revalidationTask = nil
        isRevalidating = false
    }

    func clearCache() {
        listingCache = [:]
        imageCache.removeAllObjects()
        unavailableThumbnails = []
        let cache = mediaCache
        Task {
            await cache.clear()
            status = "Cache cleared."
            startThumbnails()
        }
    }

    func setViewMode(_ mode: BrowserViewMode) {
        guard !isBusy, mode != viewMode else { return }
        viewMode = mode
        if mode == .gallery {
            startThumbnails()
        } else {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            previewScan = nil
        }
    }

    func setGrouping(_ grouping: FileGrouping) {
        guard grouping != self.grouping else { return }
        self.grouping = grouping
        regroup()
        if grouping == .location {
            startLocationScan()
        } else {
            stopLocationScan()
        }
    }

    func setSort(_ sort: FileSort) {
        guard sort != self.sort else { return }
        self.sort = sort
        regroup()
    }

    private func startBackgroundWork() {
        startThumbnails()
        startLocationScan()
    }

    private func stopLocationScan() {
        locationTask?.cancel()
        locationTask = nil
        placeNamer.cancel()
        locationScan = nil
        let cache = mediaCache
        Task { await cache.flush() }
    }

    private func startLocationScan() {
        guard grouping == .location, !isBusy, let storage else { return }
        locationTask?.cancel()
        let candidates = files.filter { $0.mediaKind == .image && locations[$0.id] == nil }
        guard !candidates.isEmpty else {
            locationScan = nil
            return
        }
        let path = folders.map(\.name)
        let keys = candidates.map { cacheKey($0, storageID: storage.id, path: path) }
        let cache = mediaCache
        locationTask = Task { [weak self] in
            // First apply everything already on disk in one update, then scan only what's missing.
            var cached: [DeviceFile.ID: PhotoLocation] = [:]
            var missing: [(DeviceFile, MediaCacheKey)] = []
            for (file, key) in zip(candidates, keys) {
                if let location = await cache.location(for: key) {
                    cached[file.id] = location
                } else {
                    missing.append((file, key))
                }
            }
            guard !Task.isCancelled, let self else { return }
            if !cached.isEmpty {
                self.locations.merge(cached) { _, new in new }
                self.regroup()
            }
            guard !missing.isEmpty else {
                self.locationScan = nil
                self.locationTask = nil
                return
            }
            self.locationScan = (0, missing.count)
            for (index, (file, key)) in missing.enumerated() {
                guard !Task.isCancelled else { return }
                var location = PhotoLocation.unknown
                var readable = true
                do {
                    if case .coordinate(let coordinate) = try await self.service.photoLocation(for: file) {
                        guard !Task.isCancelled else { return }
                        location = .place(await self.placeNamer.name(for: coordinate))
                    }
                } catch {
                    readable = false
                    NSLog("Could not read location for object %u: %@", file.id, error.localizedDescription)
                }
                guard !Task.isCancelled else { return }
                // Only remember real results: transient read errors are retried next time.
                if readable, !Self.isCoordinateFallback(location) { await cache.storeLocation(location, for: key) }
                self.locations[file.id] = location
                self.locationScan = (index + 1, missing.count)
                self.regroup()
            }
            await cache.flush()
            guard !Task.isCancelled else { return }
            self.locationScan = nil
            self.locationTask = nil
        }
    }

    /// Coordinates shown because the place-name lookup failed (e.g. offline) shouldn't be cached permanently.
    private static func isCoordinateFallback(_ location: PhotoLocation) -> Bool {
        guard case .place(let name) = location else { return false }
        return name.contains("°")
    }

    private func resetThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnails = [:]
        unavailableThumbnails = []
        previewScan = nil
    }

    private func startThumbnails() {
        guard viewMode == .gallery, !isBusy, let storage else { return }
        thumbnailTask?.cancel()
        previewScan = nil
        // Load in on-screen order so the visible cells fill in first.
        let candidates = groups.flatMap(\.files).filter {
            ($0.mediaKind == .image || $0.mediaKind == .video)
                && thumbnails[$0.id] == nil && !unavailableThumbnails.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        let path = folders.map(\.name)
        let keys = candidates.map { cacheKey($0, storageID: storage.id, path: path) }

        var missing: [(DeviceFile, MediaCacheKey)] = []
        var fromMemory: [DeviceFile.ID: NSImage] = [:]
        for (file, key) in zip(candidates, keys) {
            if let image = imageCache.object(forKey: key.value as NSString) {
                fromMemory[file.id] = image
            } else {
                missing.append((file, key))
            }
        }
        if !fromMemory.isEmpty { thumbnails.merge(fromMemory) { _, new in new } }
        guard !missing.isEmpty else { return }

        let cache = mediaCache
        thumbnailTask = Task { [weak self] in
            // 1. Disk cache, applied in batches to avoid redrawing the grid for every file.
            var uncached: [(DeviceFile, MediaCacheKey)] = []
            var batch: [DeviceFile.ID: NSImage] = [:]
            var unavailable: Set<DeviceFile.ID> = []
            for (file, key) in missing {
                switch await cache.thumbnail(for: key) {
                case .data(let data)?:
                    if let image = NSImage(data: data) {
                        batch[file.id] = image
                        self?.imageCache.setObject(image, forKey: key.value as NSString)
                    } else {
                        uncached.append((file, key))
                    }
                case .unavailable?:
                    unavailable.insert(file.id)
                case nil:
                    uncached.append((file, key))
                }
                if batch.count >= 40 {
                    guard !Task.isCancelled else { return }
                    self?.thumbnails.merge(batch) { _, new in new }
                    batch = [:]
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.thumbnails.merge(batch) { _, new in new }
            self.unavailableThumbnails.formUnion(unavailable)

            // 2. Thumbnails the phone already has. These are quick, so do them all before generating any.
            var needsPreview: [(DeviceFile, MediaCacheKey)] = []
            for (file, key) in uncached {
                guard !Task.isCancelled else { return }
                var data: Data?
                do {
                    if let raw = try await self.service.thumbnail(for: file) {
                        data = await Task.detached(priority: .utility) { ThumbnailMaker.normalizedThumbnail(raw) }.value
                    }
                } catch {
                    NSLog("Could not load device thumbnail for object %u: %@", file.id, error.localizedDescription)
                }
                guard !Task.isCancelled else { return }
                if let data, let image = NSImage(data: data) {
                    await cache.storeThumbnail(.data(data), for: key)
                    self.imageCache.setObject(image, forKey: key.value as NSString)
                    self.thumbnails[file.id] = image
                } else {
                    needsPreview.append((file, key))
                }
            }

            // 3. Everything else (screenshots, PNG/HEIC/WebP, edited or shared images, videos) is previewed on the Mac.
            guard !needsPreview.isEmpty else { return }
            self.previewScan = (0, needsPreview.count)
            for (index, (file, key)) in needsPreview.enumerated() {
                guard !Task.isCancelled else { return }
                let result = await self.makePreview(file)
                guard !Task.isCancelled else { return }
                switch result {
                case .data(let data)?:
                    await cache.storeThumbnail(.data(data), for: key)
                    if let image = NSImage(data: data) {
                        self.imageCache.setObject(image, forKey: key.value as NSString)
                        self.thumbnails[file.id] = image
                    } else {
                        self.unavailableThumbnails.insert(file.id)
                    }
                case .unavailable?:
                    await cache.storeThumbnail(.unavailable, for: key)
                    self.unavailableThumbnails.insert(file.id)
                case nil:
                    // A read error (e.g. phone locked or busy): show the icon now and try again next time.
                    self.unavailableThumbnails.insert(file.id)
                }
                self.previewScan = (index + 1, needsPreview.count)
            }
            self.previewScan = nil
        }
    }

    private static let maxImagePreviewBytes: UInt64 = 80 * 1024 * 1024
    private static let videoHeadBytes: UInt64 = 16 * 1024 * 1024
    private static let videoTailBytes: UInt64 = 8 * 1024 * 1024
    private static let maxFullVideoPreviewBytes: UInt64 = 300 * 1024 * 1024

    /// Returns nil when reading from the phone failed, so the result isn't cached.
    private func makePreview(_ file: DeviceFile) async -> CachedThumbnail? {
        do {
            switch file.mediaKind {
            case .image:
                guard file.size <= Self.maxImagePreviewBytes else { return .unavailable }
                let url = try await service.temporaryCopy(of: file)
                defer { try? FileManager.default.removeItem(at: url) }
                let data = await Task.detached(priority: .utility) { ThumbnailMaker.imageThumbnail(at: url) }.value
                return data.map(CachedThumbnail.data) ?? .unavailable
            case .video:
                // Usually the start and end of the file are enough to decode a frame.
                let partial = try await service.temporaryCopy(of: file, head: Self.videoHeadBytes, tail: Self.videoTailBytes)
                let partialData = await ThumbnailMaker.videoThumbnail(at: partial)
                try? FileManager.default.removeItem(at: partial)
                if let partialData { return .data(partialData) }
                guard file.size > Self.videoHeadBytes + Self.videoTailBytes,
                      file.size <= Self.maxFullVideoPreviewBytes else { return .unavailable }
                let full = try await service.temporaryCopy(of: file)
                defer { try? FileManager.default.removeItem(at: full) }
                return await ThumbnailMaker.videoThumbnail(at: full).map(CachedThumbnail.data) ?? .unavailable
            default:
                return .unavailable
            }
        } catch {
            NSLog("Could not create preview for %@: %@", file.name, error.localizedDescription)
            return nil
        }
    }


    func toggleSelection(_ file: DeviceFile) {
        guard !isBusy else { return }
        selectionState.click(file.id, kind: .toggle, order: displayOrder)
    }

    func click(_ file: DeviceFile, kind: SelectionClick) {
        guard !isBusy else { return }
        selectionState.click(file.id, kind: kind, order: displayOrder)
    }

    /// Double-click or Return: open a folder, or download a file.
    func activate(_ file: DeviceFile) {
        guard !isBusy else { return }
        if file.isFolder {
            open(file)
        } else {
            selectionState.click(file.id, kind: .replace, order: displayOrder)
            downloadSelected()
        }
    }

    func selectAll() {
        guard !isBusy else { return }
        selectionState.selectAll(displayOrder)
    }

    func deselectAll() {
        guard !isBusy else { return }
        selectionState.clear()
    }

    func groupSelection(_ group: FileGroup) -> GroupSelection {
        selectionState.groupState(group.files.map(\.id))
    }

    /// Selects or deselects a whole group. With `exclusive`, the group replaces the current selection.
    func toggleGroup(_ group: FileGroup, exclusive: Bool = false) {
        guard !isBusy else { return }
        selectionState.toggleGroup(group.files.map(\.id), exclusive: exclusive)
    }

    func deselectGroup(_ group: FileGroup) {
        guard !isBusy else { return }
        selectionState.deselectGroup(group.files.map(\.id))
    }

    func moveSelection(_ move: SelectionMove, extend: Bool) {
        guard !isBusy else { return }
        let sections = groups.map { $0.files.map(\.id) }
        let columns = viewMode == .gallery ? galleryColumns : 1
        // In a list, left and right have no meaning, so they behave like up and down.
        let effective: SelectionMove
        switch (viewMode, move) {
        case (.list, .left): effective = .up
        case (.list, .right): effective = .down
        default: effective = move
        }
        let pageRows = viewMode == .gallery ? 3 : 12
        guard let target = SelectionNavigator.target(
            from: selectionState.cursor, move: effective, sections: sections, columns: columns, pageRows: pageRows
        ) else { return }
        selectionState.move(to: target, extend: extend, order: displayOrder)
        scrollTarget = target
    }

    func activateCursor() {
        guard let cursor = selectionState.cursor ?? selectedFiles.first?.id,
              let file = files.first(where: { $0.id == cursor }) else { return }
        if selection.count > 1, !file.isFolder { downloadSelected(); return }
        activate(file)
    }

    func deleteSelected() {
        guard !isBusy else { return }
        let selected = selectedFiles
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(selected.count) item\(selected.count == 1 ? "" : "s") from Android?"
        alert.informativeText = "This permanently deletes the selected items from your device. Deleting a folder may also delete everything inside it. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        resetThumbnails()
        stopLocationScan()
        stopRevalidation()
        let key = listingKey
        isBusy = true
        progress = 0
        status = "Deleting 0 of \(selected.count)..."
        Task {
            let result = await DeletionRunner.run(files: selected, delete: { file in
                try await self.service.delete(file)
            }, didDelete: { completed, total in
                self.progress = Double(completed) / Double(total)
                self.status = "Deleted \(completed) of \(total)..."
            })
            let deletedIDs = Set(result.deleted.map(\.id))
            setFiles(files.filter { !deletedIDs.contains($0.id) })
            selectionState.retain(Set(files.map(\.id)))
            // Deleted folders may have cached listings of their own; drop everything except this folder.
            listingCache = [:]

            var messages: [String] = []
            if let failed = result.failed, let error = result.error {
                messages.append("Stopped at \(failed.name) after deleting \(result.deleted.count) of \(selected.count) items.\n\(error.localizedDescription)")
            }
            do {
                guard let storage else { throw MTPFailure(message: "Storage is no longer available.") }
                let listing = try await service.list(storageID: storage.id, parentID: folders.last?.id ?? rootID)
                listingCache[key] = listing
                setFiles(listing)
                selectionState.retain(Set(listing.map(\.id)))
                status = "Deleted \(result.deleted.count) of \(selected.count) items."
            } catch {
                setFiles([])
                selectionState.clear()
                status = "Could not refresh folder."
                messages.append("Could not refresh the folder after deletion. Reconnect or refresh to see its current contents.\n\(error.localizedDescription)")
            }
            if !messages.isEmpty { errorMessage = messages.joined(separator: "\n\n") }
            progress = nil
            isBusy = false
            startBackgroundWork()
        }
    }

    func downloadSelected() {
        guard !isBusy else { return }
        let downloadable = selectedFiles.filter { !$0.isFolder }
        if downloadable.count > 1 || (downloadable.count == 1 && selectedFiles.count > 1) {
            downloadMany(downloadable, skippedFolders: selectedFiles.count - downloadable.count)
            return
        }
        guard let file = downloadable.first else { return }
        let panel = NSSavePanel()
        panel.title = "Save from Android"
        panel.nameFieldStringValue = URL(fileURLWithPath: file.name).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "Choose a new file name. Android Transfer does not overwrite existing files."
            return
        }
        thumbnailTask?.cancel()
        thumbnailTask = nil
        previewScan = nil
        stopLocationScan()
        stopRevalidation()
        isBusy = true
        progress = 0
        status = "Downloading \(file.name)..."
        Task { [self] in
            do {
                try await service.download(file, to: destination) { [weak self] sent, total in
                    guard total > 0 else { return }
                    DispatchQueue.main.async {
                        guard let self, self.isBusy, self.progress != nil else { return }
                        self.progress = min(1, Double(sent) / Double(total))
                    }
                }
                status = "Saved \(destination.lastPathComponent)."
            } catch {
                status = "Transfer failed."
                errorMessage = error.localizedDescription
            }
            progress = nil
            isBusy = false
            startBackgroundWork()
        }
    }

    private func downloadMany(_ files: [DeviceFile], skippedFolders: Int) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for \(files.count) item\(files.count == 1 ? "" : "s")"
        panel.prompt = "Download"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        thumbnailTask?.cancel()
        thumbnailTask = nil
        previewScan = nil
        stopLocationScan()
        stopRevalidation()
        isBusy = true
        progress = 0
        let totalBytes = max(1, files.reduce(UInt64(0)) { $0 + $1.size })
        status = "Downloading 1 of \(files.count)..."
        Task { [self] in
            var finishedBytes: UInt64 = 0
            var saved = 0
            var reserved = Set<String>()
            var failures: [String] = []
            var consecutiveFailures = 0
            for (index, file) in files.enumerated() {
                status = "Downloading \(index + 1) of \(files.count): \(file.name)"
                let destination = DownloadNaming.uniqueDestination(for: file.name, in: folder, reserved: reserved)
                reserved.insert(destination.lastPathComponent.lowercased())
                let base = finishedBytes
                do {
                    try await service.download(file, to: destination) { [weak self] sent, _ in
                        DispatchQueue.main.async {
                            guard let self, self.isBusy, self.progress != nil else { return }
                            self.progress = min(1, Double(base + sent) / Double(totalBytes))
                        }
                    }
                    saved += 1
                    consecutiveFailures = 0
                } catch {
                    failures.append("\(file.name): \(error.localizedDescription)")
                    consecutiveFailures += 1
                    // Repeated failures usually mean the phone was unplugged or locked.
                    if consecutiveFailures >= 3 { break }
                }
                finishedBytes += file.size
                progress = min(1, Double(finishedBytes) / Double(totalBytes))
            }
            var summary = "Saved \(saved) of \(files.count) file\(files.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
            if skippedFolders > 0 {
                summary += " Skipped \(skippedFolders) folder\(skippedFolders == 1 ? "" : "s")."
            }
            status = summary
            if !failures.isEmpty {
                let shown = failures.prefix(10).joined(separator: "\n")
                let more = failures.count > 10 ? "\n…and \(failures.count - 10) more." : ""
                errorMessage = "\(failures.count) file\(failures.count == 1 ? "" : "s") could not be downloaded.\n\n\(shown)\(more)"
            }
            if saved > 0 { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            progress = nil
            isBusy = false
            startBackgroundWork()
        }
    }
}
