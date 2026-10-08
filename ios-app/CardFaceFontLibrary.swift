import SwiftUI
import UIKit
import CoreText
import UniformTypeIdentifiers

struct CardFaceImportedFont: Codable, Identifiable {
    let id: UUID
    let name: String
    let postScriptName: String
    let fileName: String
}

@MainActor
final class CardFaceFontLibrary: ObservableObject {
    static let shared = CardFaceFontLibrary()
    @Published private(set) var fonts: [CardFaceImportedFont] = []
    @Published private(set) var revision = UUID()
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CardFaceFonts", isDirectory: true)
        if let data = try? Data(contentsOf: self.root.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([CardFaceImportedFont].self, from: data) {
            fonts = saved.filter { $0.fileName == $0.id.uuidString + ".ttf" || $0.fileName == $0.id.uuidString + ".otf" }
            for font in fonts { register(font) }
        }
    }

    func availableFont(_ id: UUID?) -> CardFaceImportedFont? {
        guard let id, let font = fonts.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(font.fileName).path),
              UIFont(name: font.postScriptName, size: 16) != nil else { return nil }
        return font
    }

    private func register(_ font: CardFaceImportedFont) {
        CTFontManagerRegisterFontsForURL(root.appendingPathComponent(font.fileName) as CFURL, .process, nil)
    }

    @discardableResult
    func importFont(_ url: URL) throws -> CardFaceImportedFont {
        let suffix = url.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(suffix) else { throw FontError.invalid }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw FontError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider),
              let postScriptName = graphicsFont.postScriptName as String? else { throw FontError.invalid }
        if let existing = fonts.first(where: { $0.postScriptName == postScriptName }), availableFont(existing.id) != nil {
            return existing
        }
        // Do not replace an installed system face or a previously registered face.
        if UIFont(name: postScriptName, size: 16) != nil { throw FontError.duplicate }
        let id = UUID()
        let font = CardFaceImportedFont(id: id, name: (graphicsFont.fullName as String?) ?? url.deletingPathExtension().lastPathComponent,
                                        postScriptName: postScriptName, fileName: id.uuidString + "." + suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(font.fileName)
        try data.write(to: file, options: .atomic)
        guard CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil), UIFont(name: postScriptName, size: 16) != nil else {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: file)
            throw FontError.invalid
        }
        do {
            let updated = fonts + [font]
            try persist(updated)
            fonts = updated
            revision = UUID()
            return font
        } catch {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func delete(_ font: CardFaceImportedFont) throws {
        let updated = fonts.filter { $0.id != font.id }
        try persist(updated)
        fonts = updated
        let file = root.appendingPathComponent(font.fileName)
        CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: file)
        revision = UUID()
    }

    private func persist(_ values: [CardFaceImportedFont]) throws {
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    enum FontError: LocalizedError {
        case invalid, tooLarge, duplicate
        var errorDescription: String? {
            switch self {
            case .invalid: return "无法读取字体，请选择有效的 TTF 或 OTF 字体文件。"
            case .tooLarge: return "字体文件不能为空或超过 20 MB。"
            case .duplicate: return "该字体已注册，请选择其他字体或重新打开应用后导入。"
            }
        }
    }
}

struct CardFaceFontPicker: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var library = CardFaceFontLibrary.shared
    @Environment(\.dismiss) private var dismiss
    let selected: UUID?
    let onSelect: (UUID?) -> Void
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Button { onSelect(nil); dismiss() } label: {
                    HStack {
                        Text(AppL("默认字体")).foregroundStyle(.primary)
                        Spacer()
                        if library.availableFont(selected) == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(library.fonts) { font in
                    if library.availableFont(font.id) != nil {
                        Button { onSelect(font.id); dismiss() } label: {
                            HStack {
                                Text(font.name).font(.custom(font.postScriptName, size: 17)).foregroundStyle(.primary)
                                Spacer()
                                if selected == font.id { Image(systemName: "checkmark") }
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                do { try library.delete(font) } catch { self.error = error.localizedDescription }
                            } label: { Label(AppL("删除"), systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle(AppL("选择字体"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppL("关闭")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button(AppL("导入字体")) { importing = true } }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf")].compactMap { $0 }) { result in
                do {
                    let font = try library.importFont(result.get())
                    onSelect(font.id)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
            .alert(AppL("无法完成操作"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(AppL("确定")) { error = nil }
            } message: { Text(AppL(error ?? "")) }
        }
    }
}
