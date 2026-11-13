import Foundation
import XCTest
@testable import AndroidTransfer

final class DownloadMetadataTests: XCTestCase {
    func testApplyModificationDate() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-transfer-test-\(UUID().uuidString)")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        try MTPService.applyModificationDate(sourceDate, to: fileURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, sourceDate)
    }

    func testMissingModificationDateLeavesFileUnchanged() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-transfer-test-\(UUID().uuidString)")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)

        try MTPService.applyModificationDate(nil, to: fileURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, originalDate)
    }
}
