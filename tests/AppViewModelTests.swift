import XCTest
import UIKit
@testable import AirCard_iOS

@MainActor
final class AppViewModelTests: XCTestCase {
    func testEmptyCurrentListNeverLoadsOrWritesOldLists() {
        let defaults = UserDefaults.standard
        let keys = ["aircard.cards", "aircard-ios.cards", "airlift.cards", "mak5er.savedCards", "LumiCards.savedCards", "savedCards", "aircard.cardNames"]
        let saved = keys.map { (key: $0, value: defaults.object(forKey: $0)) }
        let previous = AppViewModel.shared
        let previousSink = AppViewModel.sharedLogSink
        defer {
            for item in saved {
                if let value = item.value { defaults.set(value, forKey: item.key) }
                else { defaults.removeObject(forKey: item.key) }
            }
            AppViewModel.shared = previous
            AppViewModel.sharedLogSink = previousSink
        }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(27)) + "="
        defaults.set([String](), forKey: "aircard.cards")
        for key in keys.dropFirst().dropLast() { defaults.set([id], forKey: key) }
        let vm = AppViewModel()
        XCTAssertTrue(vm.cards.isEmpty)
        vm.addCardHash(id)
        vm.removeCard(id: id)
        vm.loadSavedCards()
        XCTAssertTrue(vm.cards.isEmpty)
        for key in keys.dropFirst().dropLast() {
            XCTAssertEqual(defaults.stringArray(forKey: key), [id])
        }
        defaults.removeObject(forKey: "aircard.cards")
        vm.loadSavedCards()
        XCTAssertTrue(vm.cards.isEmpty)
    }

    func testNewSelectionCannotApplyOldImageWhileEncoding() async throws {
        let previous = AppViewModel.shared
        let previousSink = AppViewModel.sharedLogSink
        defer {
            AppViewModel.shared = previous
            AppViewModel.sharedLogSink = previousSink
        }
        let vm = AppViewModel()
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(27)) + "="
        let path = AppViewModel.cardImagePath(for: id)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = image(.red), intermediate = image(.green), selected = image(.blue)
        let oldData = try XCTUnwrap(ImageEngine.prepareCardImage(from: original))
        vm.cards = [CardItem(id: id, customImageData: oldData, customImage: original)]
        vm.hasPairingFile = true
        XCTAssertTrue(vm.canFlashCards)
        vm.setCardImage(for: id, image: intermediate)
        vm.setCardImage(for: id, image: selected)
        XCTAssertEqual(vm.cards[0].customImage?.cgImage?.width, 1536)
        // The main actor cannot commit either detached encoder before these assertions.
        XCTAssertEqual(vm.pendingCardImageIDs, [id])
        XCTAssertFalse(vm.canFlashCards)
        for _ in 0..<100 {
            if vm.pendingCardImageIDs.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(vm.pendingCardImageIDs.isEmpty)
        XCTAssertTrue(vm.canFlashCards)
        XCTAssertEqual(vm.cards[0].customImageData, ImageEngine.prepareCardImage(from: selected))
        XCTAssertEqual(try Data(contentsOf: path), vm.cards[0].customImageData)
    }

    func testNoPendingImagesShowsToastWithoutStartingDeviceWork() {
        let previous = AppViewModel.shared
        let previousSink = AppViewModel.sharedLogSink
        defer {
            AppViewModel.shared = previous
            AppViewModel.sharedLogSink = previousSink
        }
        let vm = AppViewModel()
        vm.cards = [CardItem(id: "abcdefghijklmnopqrstuvwxyza=")]
        vm.hasPairingFile = true
        vm.cardFlashLog = ["existing log"]
        vm.flashCards()
        XCTAssertEqual(vm.cardToast?.message, "暂无需要更新的卡面")
        XCTAssertEqual(vm.cardFlashPhase, .idle)
        XCTAssertEqual(vm.cardFlashLog, ["existing log"])
        vm.cards[0].customImage = image(.red)
        vm.cards[0].isSelected = false
        vm.flashCards()
        XCTAssertEqual(vm.cardFlashPhase, .idle)
        XCTAssertEqual(vm.cardToast?.message, "暂无需要更新的卡面")
    }

    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1536, height: 969), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1536, height: 969))
        }
    }
}
