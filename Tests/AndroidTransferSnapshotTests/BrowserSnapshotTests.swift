import AppKit
import SwiftUI
import TransferCore
import XCTest
@testable import AndroidTransfer

@MainActor
final class BrowserSnapshotTests: XCTestCase {
    func testGeneratedBrowserSnapshots() throws {
        _ = NSApplication.shared
        for scenario in BrowserSnapshot.allCases {
            let model = BrowserModel(snapshot: scenario)
            XCTAssertEqual(model.files.count, 8)
            XCTAssertEqual(model.deviceName, "Pixel 9 Pro (Demo)")
            XCTAssertTrue(model.canDownload)
            XCTAssertEqual(model.selection.count, 2)
            XCTAssertTrue(model.files.contains(where: \.isFolder))
            XCTAssertTrue(model.files.contains { $0.modifiedAt == nil })
            XCTAssertEqual(Set(model.files.compactMap(\.mediaKind)), [.image, .video, .audio])

            switch scenario {
            case .list:
                XCTAssertEqual(model.viewMode, .list)
            case .gallery:
                XCTAssertEqual(model.viewMode, .gallery)
                XCTAssertEqual(model.thumbnails.count, 3)
            case .dateGroups:
                XCTAssertEqual(model.grouping, .date)
                XCTAssertEqual(model.sort, .dateNewest)
                XCTAssertTrue(model.groups.contains { $0.title == "No date" })
            case .locationGroups:
                XCTAssertEqual(model.grouping, .location)
                XCTAssertNotNil(model.locationScan)
                XCTAssertNotNil(model.previewScan)
                XCTAssertTrue(model.groups.contains { $0.title == "Pune, India" })
                XCTAssertTrue(model.groups.contains { $0.title == "No location" })
                XCTAssertTrue(model.groups.contains { $0.title == FileGrouper.pendingLocationTitle })
            }

            let attachment = try render(model, named: String(describing: scenario))
            add(attachment)
        }
    }

    private func render(_ model: BrowserModel, named name: String) throws -> XCTAttachment {
        let size = NSSize(width: 1100, height: 760)
        let hostingView = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.couldNotAllocateBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG
        }
        XCTAssertGreaterThan(data.count, 1_000, "Snapshot \(name) should contain a rendered browser view")

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "Android Transfer - \(name)"
        attachment.lifetime = .keepAlways
        return attachment
    }

    private enum SnapshotError: Error {
        case couldNotAllocateBitmap
        case couldNotEncodePNG
    }
}
