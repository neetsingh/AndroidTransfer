import XCTest
@testable import TransferCore

final class ModelsTests: XCTestCase {
    func testFoldersBeforeFilesAndNaturalNameOrdering() {
        let entries = [
            DeviceFile(id: 1, name: "photo10.jpg", size: 10, isFolder: false),
            DeviceFile(id: 2, name: "Videos", size: 0, isFolder: true),
            DeviceFile(id: 3, name: "photo2.jpg", size: 2, isFolder: false),
            DeviceFile(id: 4, name: "Camera", size: 0, isFolder: true)
        ]
        XCTAssertEqual(FileOrdering.sorted(entries).map(\.id), [4, 2, 3, 1])
    }

    func testSameNameUsesIDAsTieBreaker() {
        let files = [
            DeviceFile(id: 5, name: "a", size: 0, isFolder: false),
            DeviceFile(id: 1, name: "a", size: 0, isFolder: false)
        ]
        XCTAssertEqual(FileOrdering.sorted(files).map(\.id), [1, 5])
    }

    func testMediaClassification() {
        XCTAssertEqual(MediaKind(filename: "PHOTO.JPG"), .image)
        XCTAssertEqual(MediaKind(filename: "clip.mp4"), .video)
        XCTAssertEqual(MediaKind(filename: "song.mp3"), .audio)
        XCTAssertNil(MediaKind(filename: "notes.txt"))
        XCTAssertNil(DeviceFile(id: 1, name: "folder.jpg", size: 0, isFolder: true).mediaKind)
    }

    func testMTPDateConversion() {
        XCTAssertNil(MTPDate.date(fromUnixTime: 0))
        XCTAssertNil(MTPDate.date(fromUnixTime: -5))
        XCTAssertEqual(MTPDate.date(fromUnixTime: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testDeletionStopsAfterFirstFailure() async {
        struct TestError: Error {}
        let files = (1...3).map { DeviceFile(id: UInt32($0), name: "\($0)", size: 0, isFolder: false) }
        var attempted: [UInt32] = []
        var progress: [Int] = []
        let result = await DeletionRunner.run(files: files, delete: { file in
            attempted.append(file.id)
            if file.id == 2 { throw TestError() }
        }, didDelete: { count, _ in progress.append(count) })
        XCTAssertEqual(attempted, [1, 2])
        XCTAssertEqual(result.deleted.map(\.id), [1])
        XCTAssertEqual(result.failed?.id, 2)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(progress, [1])
    }

    func testDeletionCompletesAllItems() async {
        let files = (1...2).map { DeviceFile(id: UInt32($0), name: "\($0)", size: 0, isFolder: false) }
        let result = await DeletionRunner.run(files: files, delete: { _ in }, didDelete: { _, _ in })
        XCTAssertEqual(result.deleted.map(\.id), [1, 2])
        XCTAssertNil(result.failed)
        XCTAssertNil(result.error)
    }
}
