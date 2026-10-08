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

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }
}
