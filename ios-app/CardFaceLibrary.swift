import Foundation
import UIKit
import SwiftUI

extension CardFaceDesign {
    var backgroundColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

extension CardFaceLayer {
    var textUIColor: UIColor { UIColor(red: textRed, green: textGreen, blue: textBlue, alpha: 1) }
}

struct CardFaceMaterial: Identifiable {
    let id: String
    let name: String
    let category: String
    static let all = [
        CardFaceMaterial(id: "MaterialBOC", name: "中国银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialABC", name: "农业银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialCOMM", name: "交通银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialCMBC", name: "民生银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialPSBC", name: "邮储银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialCCB", name: "建设银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialSPDB", name: "浦发银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialCEB", name: "光大银行", category: "银行标识"),
        CardFaceMaterial(id: "MaterialTUnion", name: "交通联合", category: "交通标识"),
        CardFaceMaterial(id: "MaterialLingnanPass", name: "岭南通", category: "交通标识"),
        CardFaceMaterial(id: "MaterialYangChengTong", name: "羊城通", category: "交通标识"),
        CardFaceMaterial(id: "MaterialGuangFoTong", name: "广佛通", category: "交通标识"),
        CardFaceMaterial(id: "MaterialBeijingTransit", name: "北京一卡通", category: "交通标识"),
        CardFaceMaterial(id: "MaterialShanghaiTransit", name: "上海交通卡", category: "交通标识"),
        CardFaceMaterial(id: "MaterialXiamenECard", name: "厦门 e通卡", category: "交通标识"),
        CardFaceMaterial(id: "MaterialVisaTone", name: "Visa · 随系统深浅", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialVisaBlue", name: "Visa · 蓝色", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialVisaNavy", name: "Visa · 深蓝", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialVisaSilver", name: "Visa · 金属银", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialMastercard", name: "Mastercard · 彩色", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialMastercardSilver", name: "Mastercard · 金属银", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialMastercardWordmark", name: "Mastercard · 带字版", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialMastercardWordmarkSilver", name: "Mastercard · 银色带字", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialMastercardClassic", name: "Mastercard · 经典版", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialUnionPay", name: "银联 · 彩色", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialUnionPaySilver", name: "银联 · 金属银", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialUnionPayBordered", name: "银联 · 白边版", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialUnionPayEnglish", name: "银联 · 英文版", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialJCB", name: "JCB", category: "卡组织标识"),
        CardFaceMaterial(id: "MaterialApple", name: "Apple", category: "品牌标识")
    ]
}

enum CardFaceRenderer {
    static let size = CGSize(width: 1536, height: 969)

    static func textImage(_ text: String, bold: Bool = false, italic: Bool = false, color: UIColor = .white, fontName: String? = nil) -> UIImage {
        // Card artwork follows the design's styles, not the device's Bold Text preference.
        // Scope this override to synchronous rendering and retain all other current traits.
        let traits = UITraitCollection(traitsFrom: [UITraitCollection.current,
                                                   UITraitCollection(legibilityWeight: .regular)])
        var image = UIImage()
        traits.performAsCurrent {
            image = renderTextImage(text, bold: bold, italic: italic, color: color, fontName: fontName)
        }
        return image
    }

    private static func renderTextImage(_ text: String, bold: Bool, italic: Bool, color: UIColor, fontName: String?) -> UIImage {
        let string = text as NSString
        let base = fontName.flatMap { UIFont(name: $0, size: 96) } ?? UIFont.systemFont(ofSize: 96, weight: bold ? .bold : .regular)
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        let baseFont = UIFont(descriptor: descriptor, size: 96)
        let measured = string.size(withAttributes: [.font: baseFont])
        let font = UIFont(descriptor: descriptor, size: 96 * min(1, 1520 / max(1, measured.width)))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let bounds = string.size(withAttributes: attributes)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // Leave room for the overhang of italic glyphs at both ends.
        let horizontalInset: CGFloat = italic ? ceil(font.pointSize * 0.3) : 8
        return UIGraphicsImageRenderer(size: CGSize(width: ceil(bounds.width) + horizontalInset * 2,
                                                    height: ceil(bounds.height) + 16), format: format).image { _ in
            string.draw(at: CGPoint(x: horizontalInset, y: 8), withAttributes: attributes)
        }
    }

    static func render(_ design: CardFaceDesign, cover: UIImage?, images: [String: UIImage]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            design.backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            cover?.draw(in: CGRect(origin: .zero, size: size))
            for layer in design.layers {
                guard let image = images[layer.imageName], image.size.width > 0 else { continue }
                let width = size.width * layer.width
                let height = width * image.size.height / image.size.width
                let cg = context.cgContext
                cg.saveGState()
                cg.setAlpha(layer.opacity)
                cg.translateBy(x: size.width * layer.x, y: size.height * layer.y)
                cg.rotate(by: layer.rotation * .pi / 180)
                image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
                cg.restoreGState()
            }
        }
    }
}

@MainActor
final class CardFaceLibraryStore: ObservableObject {
    @Published private(set) var entries: [CardFaceEntry] = []
    @Published var errorMessage: String?
    let root: URL
    private let thumbnails = NSCache<NSString, UIImage>()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CardFaceLibrary", isDirectory: true)
        reload()
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            var loaded: [CardFaceEntry] = []
            var unreadable = 0
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
                do {
                    let entry = try JSONDecoder().decode(CardFaceEntry.self, from: Data(contentsOf: folder.appendingPathComponent("entry.json")))
                    guard folder.lastPathComponent == entry.id.uuidString else { throw CardFaceLibraryError.invalidDesign }
                    loaded.append(entry)
                } catch { unreadable += 1 }
            }
            entries = loaded.sorted { $0.updatedAt > $1.updatedAt }
            if unreadable > 0 { errorMessage = "有 \(unreadable) 个设计无法读取，其余设计仍可使用。" }
        } catch {
            errorMessage = "无法读取卡面资源库：\(error.localizedDescription)"
        }
    }

    func revisionURL(_ entry: CardFaceEntry) -> URL {
        root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            .appendingPathComponent(entry.revision.uuidString, isDirectory: true)
    }

    func load(_ entry: CardFaceEntry) throws -> (CardFaceDesign, UIImage?, [String: UIImage]) {
        let folder = revisionURL(entry)
        let design = try JSONDecoder().decode(CardFaceDesign.self, from: Data(contentsOf: folder.appendingPathComponent("design.json")))
        guard design.id == entry.id else { throw CardFaceLibraryError.invalidDesign }
        try Self.validate(design)
        var images: [String: UIImage] = [:]
        for layer in design.layers {
            guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(layer.imageName).path) else {
                throw CardFaceLibraryError.imageMissing
            }
            images[layer.imageName] = image
            if let text = layer.text, layer.textFontID != nil {
                images[layer.imageName] = CardFaceRenderer.textImage(text, bold: layer.textBold, italic: layer.textItalic,
                    color: layer.textUIColor, fontName: CardFaceFontLibrary.shared.availableFont(layer.textFontID)?.postScriptName)
            }
        }
        let coverURL = folder.appendingPathComponent("cover.png")
        guard let cover = UIImage(contentsOfFile: coverURL.path) else { throw CardFaceLibraryError.imageMissing }
        return (design, cover, images)
    }

    func image(for entry: CardFaceEntry) throws -> UIImage {
        if usesImportedFonts(entry) {
            let loaded = try load(entry)
            return CardFaceRenderer.render(loaded.0, cover: loaded.1, images: loaded.2)
        }
        guard let image = UIImage(contentsOfFile: revisionURL(entry).appendingPathComponent("card.png").path) else {
            throw CardFaceLibraryError.imageMissing
        }
        return image
    }

    func thumbnail(for entry: CardFaceEntry) -> UIImage? {
        let key = (entry.revision.uuidString + CardFaceFontLibrary.shared.revision.uuidString) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        if usesImportedFonts(entry), let loaded = try? load(entry) {
            let image = ImageEngine.normalizeAndDownsample(CardFaceRenderer.render(loaded.0, cover: loaded.1, images: loaded.2), maxDimension: 512)
            thumbnails.setObject(image, forKey: key)
            return image
        }
        guard let image = UIImage(contentsOfFile: revisionURL(entry).appendingPathComponent("thumbnail.png").path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private func usesImportedFonts(_ entry: CardFaceEntry) -> Bool {
        guard let data = try? Data(contentsOf: revisionURL(entry).appendingPathComponent("design.json")),
              let design = try? JSONDecoder().decode(CardFaceDesign.self, from: data) else { return false }
        return design.layers.contains { $0.text != nil && $0.textFontID != nil }
    }

    func save(_ design: CardFaceDesign, cover: UIImage?, images: [String: UIImage]) async throws {
        guard let cover else { throw CardFaceLibraryError.imageMissing }
        try Self.validate(design)
        var images = images
        for layer in design.layers {
            guard let text = layer.text, layer.textFontID != nil else { continue }
            images[layer.imageName] = CardFaceRenderer.textImage(text, bold: layer.textBold, italic: layer.textItalic, color: layer.textUIColor,
                fontName: CardFaceFontLibrary.shared.availableFont(layer.textFontID)?.postScriptName)
        }
        let root = self.root
        let entry = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = root.appendingPathComponent(design.id.uuidString, isDirectory: true)
            let revision = UUID()
            let revisionFolder = folder.appendingPathComponent(revision.uuidString, isDirectory: true)
            let staging = root.appendingPathComponent(".\(revision.uuidString).staging", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            guard let data = cover.pngData() else { throw CardFaceLibraryError.imageMissing }
            try data.write(to: staging.appendingPathComponent("cover.png"), options: .atomic)
            for layer in design.layers {
                guard let data = images[layer.imageName]?.pngData() else { throw CardFaceLibraryError.imageMissing }
                try data.write(to: staging.appendingPathComponent(layer.imageName), options: .atomic)
            }
            try JSONEncoder().encode(design).write(to: staging.appendingPathComponent("design.json"), options: .atomic)
            let rendered = CardFaceRenderer.render(design, cover: cover, images: images)
            guard let card = rendered.pngData(),
                  let thumb = ImageEngine.normalizeAndDownsample(rendered, maxDimension: 512).pngData() else {
                throw CardFaceLibraryError.imageMissing
            }
            try card.write(to: staging.appendingPathComponent("card.png"), options: .atomic)
            try thumb.write(to: staging.appendingPathComponent("thumbnail.png"), options: .atomic)
            let entry = CardFaceEntry(id: design.id, name: design.name, revision: revision, updatedAt: Date())
            let existed = fm.fileExists(atPath: folder.appendingPathComponent("entry.json").path)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: staging, to: revisionFolder)
                // Publish the new revision only after all editable assets and rendered images exist.
                try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
            } catch {
                try? fm.removeItem(at: revisionFolder)
                if !existed { try? fm.removeItem(at: folder) }
                throw error
            }
            for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if UUID(uuidString: old.lastPathComponent) != nil, old.lastPathComponent != revision.uuidString { try? fm.removeItem(at: old) }
            }
            return entry
        }.value
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
    }

    func delete(_ entry: CardFaceEntry) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id.uuidString, isDirectory: true))
        entries.removeAll { $0.id == entry.id }
        thumbnails.removeObject(forKey: entry.revision.uuidString as NSString)
    }

    nonisolated static func validate(_ design: CardFaceDesign) throws {
        try CardFaceValidation.validate(design)
    }
}
