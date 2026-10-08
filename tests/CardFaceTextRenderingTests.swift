import XCTest
import UIKit
@testable import AirCard_iOS

@MainActor
final class CardFaceTextRenderingTests: XCTestCase {
    func testMissingFontFallsBackWithoutLosingReferenceOrStyles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardFaceLibraryStore(root: root)
        let editor = CardFaceEditorState(store: store, entry: nil)
        editor.addText("123 ABC")
        let id = try XCTUnwrap(editor.selectedLayer)
        editor.toggleTextStyle(\.textBold)
        editor.setTextColor(id: id, red: 0, green: 0, blue: 1)
        let missing = UUID()
        editor.setTextFont(id: id, fontID: missing)
        let layer = try XCTUnwrap(editor.design.layers.first)
        XCTAssertNil(CardFaceFontLibrary.shared.availableFont(missing))
        XCTAssertEqual(layer.textFontID, missing)
        let expected = try XCTUnwrap(CardFaceRenderer.textImage("123 ABC", bold: true, color: .blue).pngData())
        XCTAssertEqual(try XCTUnwrap(editor.images[layer.imageName]?.pngData()), expected)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
        try await store.save(editor.design, cover: cover, images: editor.images)
        let loaded = try store.load(XCTUnwrap(store.entries.first))
        XCTAssertEqual(loaded.0.layers.first?.textFontID, missing)
        XCTAssertEqual(try XCTUnwrap(loaded.2[layer.imageName]?.pngData()), expected)
        editor.setTextFont(id: id, fontID: nil)
        XCTAssertNil(editor.design.layers.first?.textFontID)
    }

    func testTextColorIsDrawnIntoPixels() throws {
        let image = CardFaceRenderer.textImage("123 中文 ABC", color: .red)
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        let opaquePixel = try XCTUnwrap(stride(from: 0, to: pixels.count, by: 4).first { pixels[$0 + 3] > 240 })
        XCTAssertGreaterThan(pixels[opaquePixel], 240)
        XCTAssertLessThan(pixels[opaquePixel + 1], 4)
        XCTAssertLessThan(pixels[opaquePixel + 2], 4)
    }

    func testTextColorSurvivesStyleChangesAndSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardFaceLibraryStore(root: root)
        let editor = CardFaceEditorState(store: store, entry: nil)
        editor.addText("123 中文 ABC")
        let id = try XCTUnwrap(editor.selectedLayer)
        editor.setTextColor(id: id, red: 1, green: 0, blue: 0)
        editor.toggleTextStyle(\.textBold)
        editor.toggleTextStyle(\.textItalic)
        let layer = try XCTUnwrap(editor.design.layers.first)
        XCTAssertEqual(layer.textColorHex, "#FF0000")
        XCTAssertTrue(layer.textBold && layer.textItalic)
        XCTAssertTrue(editor.hasChanges)
        let text = try XCTUnwrap(layer.text)
        let editedData = try XCTUnwrap(editor.images[layer.imageName]?.pngData())
        let expectedData = try XCTUnwrap(CardFaceRenderer.textImage(text, bold: true, italic: true, color: .red).pngData())
        XCTAssertEqual(editedData, expectedData)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try await store.save(editor.design, cover: cover, images: editor.images)
        let entry = try XCTUnwrap(store.entries.first)
        let loaded = try store.load(entry)
        XCTAssertEqual(loaded.0, editor.design)
        XCTAssertEqual(try XCTUnwrap(loaded.2[layer.imageName]?.pngData()), editedData)
    }

    func testAllTextStylesIgnoreAccessibilityBoldText() throws {
        for (bold, italic) in [(false, false), (true, false), (false, true), (true, true)] {
            let regular = try renderedData(bold: bold, italic: italic, legibility: .regular)
            let accessibilityBold = try renderedData(bold: bold, italic: italic, legibility: .bold)
            XCTAssertEqual(regular, accessibilityBold,
                           "System Bold Text must not change the artwork for bold=\(bold), italic=\(italic)")
        }
    }

    func testEditorBoldStillChangesArtwork() throws {
        for italic in [false, true] {
            XCTAssertNotEqual(try renderedData(bold: false, italic: italic, legibility: .bold),
                              try renderedData(bold: true, italic: italic, legibility: .bold))
        }
    }

    private func renderedData(bold: Bool, italic: Bool, legibility: UILegibilityWeight) throws -> Data {
        let traits = UITraitCollection(traitsFrom: [UITraitCollection.current,
                                                   UITraitCollection(legibilityWeight: legibility)])
        var data: Data?
        traits.performAsCurrent {
            let previousWeight = UITraitCollection.current.legibilityWeight
            data = CardFaceRenderer.textImage("123 中文 ABC", bold: bold, italic: italic).pngData()
            XCTAssertEqual(UITraitCollection.current.legibilityWeight, previousWeight,
                           "Rendering must restore the surrounding interface's traits")
        }
        return try XCTUnwrap(data)
    }
}
