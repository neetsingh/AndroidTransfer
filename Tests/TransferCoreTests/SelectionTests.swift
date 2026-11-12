import TransferCore
import XCTest

final class SelectionTests: XCTestCase {
    private let order: [UInt32] = [10, 11, 12, 13, 14, 15]

    func testShiftClickSelectsRangeFromAnchor() {
        var state = SelectionState()
        state.click(11, kind: .replace, order: order)
        state.click(13, kind: .extend, order: order)
        XCTAssertEqual(state.selected, [11, 12, 13])
        state.click(12, kind: .extend, order: order)
        XCTAssertEqual(state.selected, [11, 12])
    }

    func testCommandOrControlClickToggles() {
        var state = SelectionState()
        state.click(11, kind: SelectionClick(command: false, control: false, shift: false), order: order)
        state.click(15, kind: SelectionClick(command: true, control: false, shift: false), order: order)
        state.click(13, kind: SelectionClick(command: false, control: true, shift: false), order: order)
        XCTAssertEqual(state.selected, [11, 13, 15])
        state.click(15, kind: .toggle, order: order)
        XCTAssertEqual(state.selected, [11, 13])
    }

    func testShiftRangeKeepsEarlierToggledItems() {
        var state = SelectionState()
        state.click(10, kind: .replace, order: order)
        state.click(13, kind: .toggle, order: order)
        state.click(15, kind: .extend, order: order)
        XCTAssertEqual(state.selected, [10, 13, 14, 15])
    }

    func testShiftArrowGrowsAndShrinks() {
        var state = SelectionState()
        state.click(13, kind: .replace, order: order)
        state.move(to: 14, extend: true, order: order)
        state.move(to: 15, extend: true, order: order)
        XCTAssertEqual(state.selected, [13, 14, 15])
        state.move(to: 12, extend: true, order: order)
        XCTAssertEqual(state.selected, [12, 13])
        state.move(to: 11, extend: false, order: order)
        XCTAssertEqual(state.selected, [11])
    }

    func testGridNavigationAcrossSections() {
        let sections: [[UInt32]] = [[1, 2, 3, 4, 5], [6, 7]]
        func go(_ from: UInt32?, _ move: SelectionMove) -> UInt32? {
            SelectionNavigator.target(from: from, move: move, sections: sections, columns: 3, pageRows: 2)
        }
        XCTAssertEqual(go(nil, .down), 1)
        XCTAssertEqual(go(3, .down), 5)
        XCTAssertEqual(go(5, .down), 7)
        XCTAssertEqual(go(6, .up), 4)
        XCTAssertEqual(go(3, .right), 4)
        XCTAssertEqual(go(1, .pageDown), 6)
        XCTAssertEqual(go(4, .last), 7)
    }

    func testGroupSelection() {
        var state = SelectionState()
        state.click(10, kind: .replace, order: order)
        state.toggleGroup([12, 13, 14])
        XCTAssertEqual(state.selected, [10, 12, 13, 14])
        XCTAssertEqual(state.groupState([12, 13, 14]), .all)
        XCTAssertEqual(state.groupState([14, 15]), .some)
        state.toggleGroup([12, 13, 14])
        XCTAssertEqual(state.selected, [10])
        state.toggleGroup([12, 13], exclusive: true)
        XCTAssertEqual(state.selected, [12, 13])
        state.deselectGroup([13])
        XCTAssertEqual(state.selected, [12])
    }
}
