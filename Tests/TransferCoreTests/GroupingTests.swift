import ImageIO
import TransferCore
import XCTest

final class GroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var files: [DeviceFile] {
        [
            DeviceFile(id: 1, name: "DCIM", size: 0, isFolder: true),
            DeviceFile(id: 2, name: "old.jpg", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-86_400 * 10)),
            DeviceFile(id: 3, name: "a.jpg", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-60)),
            DeviceFile(id: 4, name: "b.jpg", size: 1, isFolder: false, modifiedAt: now),
            DeviceFile(id: 5, name: "y.mp4", size: 1, isFolder: false, modifiedAt: now.addingTimeInterval(-86_400)),
            DeviceFile(id: 6, name: "x.txt", size: 1, isFolder: false)
        ]
    }

    func testGroupsByDayNewestFirst() {
        let groups = FileGrouper.groups(files, by: .date, sort: .dateNewest, calendar: utc, now: now)
        XCTAssertEqual(groups.prefix(3).map(\.title), ["Folders", "Today", "Yesterday"])
        XCTAssertEqual(groups.last?.id, "no-date")
        XCTAssertEqual(groups[1].files.map(\.id), [4, 3])
        XCTAssertEqual(groups[3].files.map(\.id), [2])
    }

    func testGroupsPhotosByPlace() {
        let groups = FileGrouper.groups(files, by: .location, locations: [3: .place("Pune, India"), 4: .place("Bengaluru, India")], sort: .dateNewest)
        XCTAssertEqual(groups.map(\.title), [
            "Folders", "Bengaluru, India", "Pune, India", FileGrouper.pendingLocationTitle, FileGrouper.unknownLocationTitle
        ])
        XCTAssertEqual(groups[3].files.map(\.id), [2])
        XCTAssertEqual(groups[4].files.map(\.id), [5, 6])
    }

    func testNoGroupingKeepsOrder() {
        XCTAssertEqual(FileGrouper.groups(files, by: .none).first?.files.map(\.id), files.map(\.id))
        XCTAssertTrue(FileGrouper.groups([], by: .none).isEmpty)
    }

    func testSortOrdersKeepFoldersFirst() {
        XCTAssertEqual(FileOrdering.sorted(files, by: .nameAscending).map(\.id), [1, 3, 4, 2, 6, 5])
        XCTAssertEqual(FileOrdering.sorted(files, by: .nameDescending).map(\.id), [1, 5, 6, 2, 4, 3])
        XCTAssertEqual(FileOrdering.sorted(files, by: .dateNewest).map(\.id), [1, 4, 3, 5, 2, 6])
        XCTAssertEqual(FileOrdering.sorted(files, by: .dateOldest).map(\.id), [1, 2, 5, 3, 4, 6])
    }

    func testCacheKeyChangesWithFileContents() {
        let file = files[2]
        let key = MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: file)
        XCTAssertEqual(key, MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: file))
        let edited = DeviceFile(id: file.id, name: file.name, size: file.size + 1, isFolder: false, modifiedAt: file.modifiedAt)
        XCTAssertNotEqual(key, MediaCacheKey(device: "phone", storageID: 1, path: ["DCIM"], file: edited))
    }

    func testMediaCachePersistsAndClears() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = MediaCacheKey(device: "phone", storageID: 1, path: [], file: files[2])
        let cache = MediaCache(directory: directory)
        await cache.storeThumbnail(.data(Data([1, 2])), for: key)
        await cache.storeLocation(.place("Pune"), for: key)
        await cache.flush()
        let reopened = MediaCache(directory: directory)
        let thumbnail = await reopened.thumbnail(for: key)
        let location = await reopened.location(for: key)
        XCTAssertEqual(thumbnail, .data(Data([1, 2])))
        XCTAssertEqual(location, .place("Pune"))
        await reopened.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReadsSignedGPSCoordinates() {
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 40.7128, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.006, kCGImagePropertyGPSLongitudeRef: "W"
        ] as [CFString: Any]]
        XCTAssertEqual(PhotoMetadata.location(fromProperties: properties),
                       .coordinate(GPSCoordinate(latitude: 40.7128, longitude: -74.006)!))
        XCTAssertEqual(PhotoMetadata.location(fromProperties: [kCGImagePropertyPixelWidth: 10]), .noLocation)
        XCTAssertEqual(PhotoMetadata.location(fromImageData: Data([0, 1, 2])), .unreadable)
        XCTAssertNil(GPSCoordinate(latitude: 0, longitude: 0))
    }
}
