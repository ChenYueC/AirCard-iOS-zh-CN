import SwiftUI

private struct CardFaceEditorRequest: Identifiable {
    let id = UUID()
    var entry: CardFaceEntry?
}

struct CardFaceLibraryView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var fonts = CardFaceFontLibrary.shared
    @EnvironmentObject private var library: CardFaceLibraryStore
    @Environment(\.dismiss) private var dismiss
    var onChoose: ((UIImage) -> Void)? = nil
    @State private var editorRequest: CardFaceEditorRequest?
    @State private var pendingDelete: CardFaceEntry?
    @State private var confirmDelete = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.entries.isEmpty {
                    ContentUnavailableView {
                        Label(AppL("还没有保存的卡面"), systemImage: "rectangle.stack")
                    } description: {
                        Text(AppL(onChoose == nil ? "添加封面和 Logo，设计自己的卡面后保存到这里。" : "请先在资源库中保存卡面设计，再返回这里选择。"))
                    } actions: {
                        if onChoose == nil {
                            Button(AppL("新建设计")) { editorRequest = CardFaceEditorRequest() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 70)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(library.entries) { entry in
                            entryView(entry)
                        }
                    }
                    .padding()
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppL("卡面资源库"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onChoose != nil {
                    ToolbarItem(placement: .cancellationAction) { Button(AppL("取消")) { dismiss() } }
                }
                if onChoose == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editorRequest = CardFaceEditorRequest() } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(AppL("新建设计"))
                    }
                }
            }
            .sheet(item: $editorRequest) { request in
                CardFaceEditorView(store: library, entry: request.entry)
            }
            .alert(AppL("删除此设计？"), isPresented: $confirmDelete) {
                Button(AppL("取消"), role: .cancel) { pendingDelete = nil }
                Button(AppL("删除"), role: .destructive) {
                    if let entry = pendingDelete {
                        do { try library.delete(entry) }
                        catch { localError = error.localizedDescription }
                    }
                    pendingDelete = nil
                }
            } message: { Text(AppL("将删除资源库中的设计和素材。已设置到钱包卡片的图片及原始卡面备份不受影响。")) }
            .alert(AppL("无法完成操作"), isPresented: Binding(
                get: { localError != nil || library.errorMessage != nil },
                set: { if !$0 { localError = nil; library.errorMessage = nil } }
            )) {
                Button(AppL("确定")) { localError = nil; library.errorMessage = nil }
            } message: { Text(AppL(localError ?? library.errorMessage ?? "")) }
        }
        .onChange(of: fonts.revision) { _, _ in library.reload() }
    }

    private func entryView(_ entry: CardFaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let onChoose {
                    do {
                        onChoose(try library.image(for: entry))
                        dismiss()
                    } catch { localError = error.localizedDescription }
                } else {
                    editorRequest = CardFaceEditorRequest(entry: entry)
                }
            } label: {
                Group {
                    if let image = library.thumbnail(for: entry) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
                .aspectRatio(1536.0 / 969.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppL(onChoose == nil ? "编辑\(entry.name)" : "使用\(entry.name)"))
            HStack {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 2)
                if onChoose == nil {
                    Menu {
                        Button(AppL("编辑"), systemImage: "pencil") { editorRequest = CardFaceEditorRequest(entry: entry) }
                        Button(AppL("删除"), systemImage: "trash", role: .destructive) {
                            pendingDelete = entry
                            confirmDelete = true
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                }
            }
        }
    }
}
