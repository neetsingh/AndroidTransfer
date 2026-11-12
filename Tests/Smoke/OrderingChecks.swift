import ImageIO
import Foundation

@main
struct OrderingChecks {
    static func main() async {
        let files = [
            DeviceFile(id: 1, name: "photo10.jpg", size: 10, isFolder: false),
            DeviceFile(id: 2, name: "Videos", size: 0, isFolder: true),
            DeviceFile(id: 3, name: "photo2.jpg", size: 2, isFolder: false),
            DeviceFile(id: 4, name: "Camera", size: 0, isFolder: true)
        ]
        precondition(FileOrdering.sorted(files).map(\.id) == [4, 2, 3, 1])
        let ties = [
            DeviceFile(id: 5, name: "a", size: 0, isFolder: false),
            DeviceFile(id: 1, name: "a", size: 0, isFolder: false)
        ]
        precondition(FileOrdering.sorted(ties).map(\.id) == [1, 5])
        precondition(MediaKind(filename: "PHOTO.JPG") == .image)
        precondition(MediaKind(filename: "clip.mp4") == .video)
        precondition(MediaKind(filename: "song.mp3") == .audio)
        precondition(MediaKind(filename: "notes.txt") == nil)
        precondition(DeviceFile(id: 1, name: "folder.jpg", size: 0, isFolder: true).mediaKind == nil)
        precondition(MTPDate.date(fromUnixTime: 0) == nil)
        precondition(MTPDate.date(fromUnixTime: -5) == nil)
        let downloads = URL(fileURLWithPath: "/tmp/dl")
        let onDisk: Set<String> = ["IMG.jpg", "IMG (2).jpg"]
        let exists: (URL) -> Bool = { onDisk.contains($0.lastPathComponent) }
        precondition(DownloadNaming.uniqueDestination(for: "new.jpg", in: downloads, exists: exists).lastPathComponent == "new.jpg")
        precondition(DownloadNaming.uniqueDestination(for: "IMG.jpg", in: downloads, exists: exists).lastPathComponent == "IMG (3).jpg")
        precondition(DownloadNaming.uniqueDestination(for: "a.png", in: downloads, reserved: ["a.png"], exists: exists).lastPathComponent == "a (2).png")
        precondition(DownloadNaming.uniqueDestination(for: "README", in: downloads, reserved: ["readme"], exists: exists).lastPathComponent == "README (2)")
        precondition(DownloadNaming.uniqueDestination(for: "../x.jpg", in: downloads, exists: exists).path == "/tmp/dl/x.jpg")
        precondition(MTPDate.date(fromUnixTime: 1_700_000_000) == Date(timeIntervalSince1970: 1_700_000_000))
        precondition(DeviceFile(id: 1, name: "a", size: 0, isFolder: false).modifiedAt == nil)
        struct TestError: Error {}
        let deletions = (1...3).map { DeviceFile(id: UInt32($0), name: "\($0)", size: 0, isFolder: false) }
        var attempted: [UInt32] = []
        var progress: [Int] = []
        let failed = await DeletionRunner.run(files: deletions, delete: { file in
            attempted.append(file.id)
            if file.id == 2 { throw TestError() }
        }, didDelete: { count, _ in progress.append(count) })
        precondition(attempted == [1, 2])
        precondition(failed.deleted.map(\.id) == [1] && failed.failed?.id == 2 && failed.error != nil)
        precondition(progress == [1])
        let succeeded = await DeletionRunner.run(files: deletions, delete: { _ in }, didDelete: { _, _ in })
        precondition(succeeded.deleted.count == 3 && succeeded.failed == nil && succeeded.error == nil)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let groupFiles = [
            DeviceFile(id: 1, name: "DCIM", size: 0, isFolder: true),
            DeviceFile(id: 2, name: "old.jpg", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-86_400 * 10)),
            DeviceFile(id: 3, name: "a.jpg", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-60)),
            DeviceFile(id: 4, name: "b.jpg", size: 1, isFolder: false, modifiedAt: now),
            DeviceFile(id: 5, name: "y.mp4", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-86_400)),
            DeviceFile(id: 6, name: "x.txt", size: 1, isFolder: false)
        ]
        let byDate = FileGrouper.groups(groupFiles, by: .date, sort: .dateNewest, calendar: utc, now: now)
        precondition(byDate.map(\.title).prefix(3) == ["Folders", "Today", "Yesterday"])
        precondition(byDate.map(\.id).last == "no-date" && byDate.count == 5)
        precondition(byDate[1].files.map(\.id) == [4, 3])
        precondition(byDate[3].files.map(\.id) == [2])
        precondition(FileGrouper.groups(groupFiles, by: .none).map(\.files.count) == [6])
        precondition(FileGrouper.groups([], by: .none).isEmpty)
        let byPlace = FileGrouper.groups(groupFiles, by: .location, locations: [3: .place("Pune, India"), 4: .place("Bengaluru, India")], sort: .dateNewest)
        precondition(byPlace.map(\.title) == ["Folders", "Bengaluru, India", "Pune, India", FileGrouper.pendingLocationTitle, FileGrouper.unknownLocationTitle])
        precondition(byPlace[3].files.map(\.id) == [2])
        precondition(byPlace[4].files.map(\.id) == [5, 6])
        let placeUnknown = FileGrouper.groups(groupFiles, by: .location, locations: [2: .unknown, 3: .place("Pune"), 4: .place("Pune")], sort: .dateNewest)
        precondition(placeUnknown.map(\.title) == ["Folders", "Pune", FileGrouper.unknownLocationTitle])
        precondition(placeUnknown[2].files.map(\.id) == [5, 2, 6])
        precondition(GPSCoordinate(latitude: 0, longitude: 0) == nil)
        precondition(GPSCoordinate(latitude: 91, longitude: 0) == nil)
        precondition(GPSCoordinate(latitude: -33.8688, longitude: 151.2093)?.displayText == "33.87°S, 151.21°E")
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 40.7128, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.006, kCGImagePropertyGPSLongitudeRef: "W"
        ] as [CFString: Any]]
        precondition(PhotoMetadata.location(fromProperties: gps) == .coordinate(GPSCoordinate(latitude: 40.7128, longitude: -74.006)!))
        precondition(PhotoMetadata.location(fromProperties: [kCGImagePropertyPixelWidth: 10]) == .noLocation)
        precondition(PhotoMetadata.location(fromImageData: Data([0, 1, 2])) == .unreadable)
        let oldestFirst = FileGrouper.groups(groupFiles, by: .date, sort: .dateOldest, calendar: utc, now: now)
        precondition(oldestFirst.map(\.id).dropFirst().first != "day-\(Int(utc.startOfDay(for: now).timeIntervalSince1970))")
        precondition(oldestFirst[1].files.map(\.id) == [2] && oldestFirst.last?.id == "no-date")
        precondition(FileGrouper.groups(groupFiles, by: .date, sort: .nameAscending, calendar: utc, now: now)[1].files.map(\.id) == [3, 4])
        precondition(FileOrdering.sorted(groupFiles, by: .nameAscending).map(\.id) == [1, 3, 4, 2, 6, 5])
        precondition(FileOrdering.sorted(groupFiles, by: .nameDescending).map(\.id) == [1, 5, 6, 2, 4, 3])
        precondition(FileOrdering.sorted(groupFiles, by: .dateNewest).map(\.id) == [1, 4, 3, 5, 2, 6])
        precondition(FileOrdering.sorted(groupFiles, by: .dateOldest).map(\.id) == [1, 2, 5, 3, 4, 6])
        let sample = groupFiles[2]
        let key = MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: sample)
        precondition(key == MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: sample))
        precondition(key != MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM", "Camera"], file: sample))
        precondition(key != MediaCacheKey(device: "other", storageID: 1, path: ["DCIM"], file: sample))
        let edited = DeviceFile(id: sample.id, name: sample.name, size: sample.size + 1, isFolder: false, modifiedAt: sample.modifiedAt)
        precondition(key != MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: edited))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("at-cache-\(UUID().uuidString)")
        let cache = MediaCache(directory: directory)
        let missingThumbnail = await cache.thumbnail(for: key)
        precondition(missingThumbnail == nil)
        await cache.storeThumbnail(.data(Data([1, 2, 3])), for: key)
        let storedThumbnail = await cache.thumbnail(for: key)
        precondition(storedThumbnail == .data(Data([1, 2, 3])))
        let otherKey = MediaCacheKey(device: "phone", storageID: 1, path: [], file: sample)
        await cache.storeThumbnail(.unavailable, for: otherKey)
        let unavailableThumbnail = await cache.thumbnail(for: otherKey)
        precondition(unavailableThumbnail == .unavailable)
        await cache.storeLocation(.place("Pune"), for: key)
        await cache.storeLocation(.unknown, for: otherKey)
        await cache.flush()
        let reopened = MediaCache(directory: directory)
        let place = await reopened.location(for: key)
        let unknown = await reopened.location(for: otherKey)
        precondition(place == .place("Pune") && unknown == .unknown)
        await reopened.storeThumbnail(.data(Data(repeating: 7, count: 1000)), for: key)
        await reopened.prune(maxBytes: 100)
        let pruned = await reopened.thumbnail(for: key)
        precondition(pruned == nil)
        await reopened.clear()
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("at-preview-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: 1080, height: 2400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pngDestination = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(pngDestination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(pngDestination))
        let preview = ThumbnailMaker.imageThumbnail(at: pngURL)
        try? FileManager.default.removeItem(at: pngURL)
        let previewSource = CGImageSourceCreateWithData(preview! as CFData, nil)!
        let previewProperties = CGImageSourceCopyPropertiesAtIndex(previewSource, 0, nil) as! [CFString: Any]
        precondition((previewProperties[kCGImagePropertyPixelHeight] as! Int) == ThumbnailMaker.maxPixelSize)
        precondition(ThumbnailMaker.normalizedThumbnail(preview!) != nil)
        precondition(ThumbnailMaker.normalizedThumbnail(Data([1, 2, 3])) == nil)
        let notAVideo = await ThumbnailMaker.videoThumbnail(at: URL(fileURLWithPath: "/nonexistent.mp4"))
        precondition(notAVideo == nil)
        let order: [UInt32] = [10, 11, 12, 13, 14, 15]
        var picked = SelectionState()
        picked.click(11, kind: .replace, order: order)
        picked.click(13, kind: .extend, order: order)
        precondition(picked.selected == [11, 12, 13] && picked.anchor == 11 && picked.cursor == 13)
        picked.click(12, kind: .extend, order: order)
        precondition(picked.selected == [11, 12])
        picked.click(15, kind: .toggle, order: order)
        precondition(picked.selected == [11, 12, 15] && picked.anchor == 15)
        picked.click(14, kind: .extend, order: order)
        precondition(picked.selected == [11, 12, 14, 15])
        picked.click(12, kind: .toggle, order: order)
        precondition(picked.selected == [11, 14, 15])
        picked.click(10, kind: .extendAdding, order: order)
        precondition(picked.selected == [10, 11, 12, 14, 15])
        picked.click(13, kind: .replace, order: order)
        picked.move(to: 14, extend: true, order: order)
        picked.move(to: 15, extend: true, order: order)
        precondition(picked.selected == [13, 14, 15] && picked.cursor == 15)
        picked.move(to: 12, extend: true, order: order)
        precondition(picked.selected == [12, 13])
        picked.move(to: 11, extend: false, order: order)
        precondition(picked.selected == [11] && picked.anchor == 11)
        picked.selectAll(order)
        precondition(picked.selected == Set(order))
        picked.retain([10, 11])
        precondition(picked.selected == [10, 11])
        picked.clear()
        precondition(picked.selected.isEmpty && picked.cursor == nil)
        precondition(SelectionClick(command: true, control: false, shift: false) == .toggle)
        precondition(SelectionClick(command: false, control: true, shift: false) == .toggle)
        precondition(SelectionClick(command: false, control: false, shift: true) == .extend)
        precondition(SelectionClick(command: true, control: false, shift: true) == .extendAdding)

        // Grid: section A has 5 items in 3 columns (rows [1,2,3],[4,5]); section B has [6,7].
        let sections: [[UInt32]] = [[1, 2, 3, 4, 5], [6, 7]]
        func go(_ from: UInt32?, _ move: SelectionMove) -> UInt32? {
            SelectionNavigator.target(from: from, move: move, sections: sections, columns: 3, pageRows: 2)
        }
        precondition(go(nil, .down) == 1 && go(nil, .up) == 7)
        precondition(go(2, .down) == 5 && go(3, .down) == 5 && go(5, .down) == 7 && go(4, .down) == 6)
        precondition(go(6, .up) == 4 && go(5, .up) == 2 && go(2, .up) == 1 && go(7, .down) == 7)
        precondition(go(3, .right) == 4 && go(1, .left) == 1 && go(7, .right) == 7)
        precondition(go(1, .pageDown) == 6 && go(6, .pageUp) == 1 && go(4, .last) == 7 && go(4, .first) == 1)
        precondition(SelectionNavigator.target(from: 2, move: .down, sections: [[1, 2, 3]], columns: 1) == 3)
        precondition(SelectionNavigator.target(from: nil, move: .down, sections: [], columns: 3) == nil)
        precondition(SelectionNavigator.adaptiveColumns(width: 500, minimum: 135, spacing: 16, padding: 16) == 3)
        precondition(SelectionNavigator.adaptiveColumns(width: 100, minimum: 135, spacing: 16, padding: 16) == 1)
        var grouped = SelectionState()
        grouped.click(10, kind: .replace, order: order)
        precondition(grouped.groupState([12, 13, 14]) == .none)
        grouped.toggleGroup([12, 13, 14])
        precondition(grouped.selected == [10, 12, 13, 14] && grouped.anchor == 12)
        precondition(grouped.groupState([12, 13, 14]) == .all && grouped.groupState([14, 15]) == .some)
        grouped.click(15, kind: .extend, order: order)
        precondition(grouped.selected == [10, 12, 13, 14, 15])
        grouped.toggleGroup([12, 13, 14])
        precondition(grouped.selected == [10, 15])
        grouped.toggleGroup([14, 15])
        precondition(grouped.selected == [10, 14, 15])
        grouped.toggleGroup([12, 13], exclusive: true)
        precondition(grouped.selected == [12, 13])
        grouped.toggleGroup([12, 13], exclusive: true)
        precondition(grouped.selected == [12, 13])
        grouped.deselectGroup([13, 14])
        precondition(grouped.selected == [12])
        grouped.toggleGroup([])
        precondition(grouped.selected == [12])
        print("Ordering checks passed")
    }
}
