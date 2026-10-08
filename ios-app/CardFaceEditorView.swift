import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class CardFaceEditorState: ObservableObject {
    @Published var design = CardFaceDesign()
    @Published var cover: UIImage?
    @Published var images: [String: UIImage] = [:]
    @Published var selectedLayer: UUID?
    @Published var errorMessage: String?
    @Published var loadFailed = false
    private var initialDesign = CardFaceDesign()
    private var initialCover: UIImage?

    var hasChanges: Bool {
        design != initialDesign || cover !== initialCover
    }

    init(store: CardFaceLibraryStore, entry: CardFaceEntry?) {
        if entry == nil { design.name = AppL("新卡面") }
        initialDesign = design
        guard let entry else { return }
        do {
            let loaded = try store.load(entry)
            design = loaded.0
            cover = loaded.1
            images = loaded.2
            selectedLayer = design.layers.first?.id
            initialDesign = design
            initialCover = cover
        } catch {
            errorMessage = error.localizedDescription
            loadFailed = true
        }
    }

    func add(_ image: UIImage, title: String) {
        guard design.layers.count < 24 else { errorMessage = "每个卡面最多添加 24 个素材。"; return }
        let id = UUID()
        let name = id.uuidString + ".png"
        images[name] = ImageEngine.normalizeAndDownsample(image, maxDimension: 1536)
        design.layers.append(CardFaceLayer(id: id, imageName: name, title: title))
        selectedLayer = id
    }

    func changeSelected(_ change: (inout CardFaceLayer) -> Void) {
        guard let index = design.layers.firstIndex(where: { $0.id == selectedLayer }) else { return }
        change(&design.layers[index])
    }

    func addText(_ text: String) {
        guard design.layers.count < 24 else { errorMessage = "每个卡面最多添加 24 个素材。"; return }
        add(CardFaceRenderer.textImage(text), title: String(text.prefix(5)) + (text.count > 5 ? "…" : ""))
        changeSelected { $0.text = text }
    }

    func toggleTextStyle(_ keyPath: WritableKeyPath<CardFaceLayer, Bool>) {
        guard let index = design.layers.firstIndex(where: { $0.id == selectedLayer }),
              let text = design.layers[index].text else { return }
        design.layers[index][keyPath: keyPath].toggle()
        let layer = design.layers[index]
        images[layer.imageName] = CardFaceRenderer.textImage(text, bold: layer.textBold, italic: layer.textItalic, color: layer.textUIColor,
            fontName: CardFaceFontLibrary.shared.availableFont(layer.textFontID)?.postScriptName)
    }

    func setTextColor(id: UUID, red: Double, green: Double, blue: Double) {
        guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let index = design.layers.firstIndex(where: { $0.id == id }),
              let text = design.layers[index].text else { return }
        design.layers[index].textRed = red
        design.layers[index].textGreen = green
        design.layers[index].textBlue = blue
        let layer = design.layers[index]
        images[layer.imageName] = CardFaceRenderer.textImage(text, bold: layer.textBold, italic: layer.textItalic, color: layer.textUIColor,
            fontName: CardFaceFontLibrary.shared.availableFont(layer.textFontID)?.postScriptName)
    }

    func setTextFont(id: UUID, fontID: UUID?) {
        guard let index = design.layers.firstIndex(where: { $0.id == id && $0.text != nil }) else { return }
        design.layers[index].textFontID = fontID
        refreshFontImages()
    }

    func refreshFontImages() {
        for layer in design.layers {
            guard let text = layer.text else { continue }
            images[layer.imageName] = CardFaceRenderer.textImage(text, bold: layer.textBold, italic: layer.textItalic, color: layer.textUIColor,
                fontName: CardFaceFontLibrary.shared.availableFont(layer.textFontID)?.postScriptName)
        }
    }

    func removeLayer(id: UUID) {
        guard let index = design.layers.firstIndex(where: { $0.id == id }) else { return }
        images.removeValue(forKey: design.layers[index].imageName)
        design.layers.remove(at: index)
        if selectedLayer == id {
            selectedLayer = design.layers.isEmpty
                ? nil
                : design.layers[min(index, design.layers.count - 1)].id
        }
    }

    func moveLayer(id: UUID, to targetID: UUID) -> Bool {
        guard design.moveLayer(id: id, to: targetID) else { return false }
        selectedLayer = id
        return true
    }
}

private enum FaceImportRequest: String, Identifiable {
    case coverPhotos, coverFiles, logoFiles
    var id: String { rawValue }
}

private struct FaceCoverCrop: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct LayerRemovalButtonFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CardFaceEditorView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject private var fonts = CardFaceFontLibrary.shared
    @State private var fontLayer: UUID?
    let store: CardFaceLibraryStore
    @StateObject private var editor: CardFaceEditorState
    @Environment(\.dismiss) private var dismiss
    @State private var importRequest: FaceImportRequest?
    @State private var pendingCrop: FaceCoverCrop?
    @State private var activeCrop: FaceCoverCrop?
    @State private var showMaterials = false
    @State private var showLogoPhotos = false
    @State private var logoPhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var dropTarget: UUID?
    @State private var pendingLayerRemoval: UUID?
    @State private var removalButtonFrames: [UUID: CGRect] = [:]
    @State private var alignmentGuides: CardFaceAlignment.Result?
    @State private var panelExpanded = true
    @State private var customText = ""
    @State private var toast: AppToast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: CardFaceLibraryStore, entry: CardFaceEntry? = nil) {
        self.store = store
        _editor = StateObject(wrappedValue: CardFaceEditorState(store: store, entry: entry))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let bottomInset = geometry.safeAreaInsets.bottom
                let panelHeight = panelExpanded ? geometry.size.height * 0.56 : 68
                let canvasWidth = max(1, min(geometry.size.width - 32,
                    (geometry.size.height - panelHeight - 32) * 1536 / 969))
                VStack(spacing: 0) {
                    canvas
                        .frame(width: canvasWidth, height: canvasWidth * 969 / 1536)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 16)
                    adjustmentPanel(height: panelHeight + bottomInset, bottomInset: bottomInset)
                }
                .frame(height: geometry.size.height + bottomInset, alignment: .top)
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .coordinateSpace(name: "cardFaceEditor")
            .contentShape(Rectangle())
            .onPreferenceChange(LayerRemovalButtonFrames.self) { removalButtonFrames = $0 }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("cardFaceEditor"))
                .onEnded { tap in
                    // Let × / checkmark handle their own taps without cancelling confirmation.
                    guard !removalButtonFrames.values.contains(where: { $0.contains(tap.location) }) else { return }
                    pendingLayerRemoval = nil
                })
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppL("设计卡面"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppL("取消")) {
                        pendingLayerRemoval = nil
                        if editor.hasChanges { confirmDiscard = true }
                        else { dismiss() }
                    }
                        .disabled(saving || loadingPhoto)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppL("保存")) { pendingLayerRemoval = nil; save() }
                        .fontWeight(.semibold)
                        .disabled(saving || loadingPhoto || editor.loadFailed || editor.cover == nil || editor.design.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving || loadingPhoto)
            .overlay {
                if saving || loadingPhoto {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView(AppL(saving ? "正在保存卡面…" : "正在载入素材…"))
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .interactiveDismissDisabled()
            .alert(AppL("放弃此次编辑？"), isPresented: $confirmDiscard) {
                Button(AppL("继续编辑"), role: .cancel) {}
                Button(AppL("放弃"), role: .destructive) { dismiss() }
            } message: { Text(AppL("未保存的修改会丢失，资源库中已有的卡面不受影响。")) }
            .alert(AppL("无法完成操作"), isPresented: Binding(
                get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } }
            )) { Button(AppL("确定")) { editor.errorMessage = nil } }
              message: { Text(AppL(editor.errorMessage ?? "")) }
            .sheet(item: $importRequest, onDismiss: {
                if let crop = pendingCrop { pendingCrop = nil; activeCrop = crop }
            }) { request in
                if request == .coverPhotos {
                    CardPhotoPicker { editor.cover = $0 }
                } else {
                    DocumentPickerView(allowedContentTypes: [.image]) { url in
                        do {
                            let data = try Data(contentsOf: url)
                            guard let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) else {
                                throw CardFaceLibraryError.imageMissing
                            }
                            if request == .coverFiles { pendingCrop = FaceCoverCrop(image: image) }
                            else { editor.add(image, title: url.deletingPathExtension().lastPathComponent) }
                        } catch { editor.errorMessage = error.localizedDescription }
                    }
                }
            }
            .sheet(item: $activeCrop) { crop in
                CardPhotoCropView(image: crop.image) { editor.cover = $0 }
            }
            .sheet(isPresented: $showMaterials) {
                CardFaceMaterialPicker { image, title in editor.add(image, title: title) }
            }
            .sheet(isPresented: Binding(get: { fontLayer != nil }, set: { if !$0 { fontLayer = nil } })) {
                if let id = fontLayer, let layer = editor.design.layers.first(where: { $0.id == id }) {
                    CardFaceFontPicker(selected: layer.textFontID) { editor.setTextFont(id: id, fontID: $0) }
                }
            }
            .onChange(of: fonts.revision) { _, _ in editor.refreshFontImages() }
            .onChange(of: editor.selectedLayer) { _, _ in
                pendingLayerRemoval = nil
                alignmentGuides = nil
            }
            .photosPicker(isPresented: $showLogoPhotos, selection: $logoPhoto, matching: .images)
            .onChange(of: logoPhoto) { _, item in
                guard let item else { return }
                loadingPhoto = true
                Task {
                    defer { loadingPhoto = false; logoPhoto = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = ImageEngine.safeImageFromData(data, maxDimension: 1536) else {
                            throw CardFaceLibraryError.imageMissing
                        }
                        editor.add(image, title: "自定义素材")
                    } catch { editor.errorMessage = error.localizedDescription }
                }
            }
        }
        .toast($toast)
    }

    private func togglePanel(_ expanded: Bool) {
        pendingLayerRemoval = nil
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08)) {
            panelExpanded = expanded
        }
    }

    private func adjustmentPanel(height: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { togglePanel(!panelExpanded) } label: {
                VStack(spacing: 6) {
                    Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 4)
                    HStack {
                        Text(AppL("图层与调整"))
                            .font(.subheadline.weight(.semibold))
                            .transaction { $0.animation = nil }
                        Spacer()
                        ZStack(alignment: .trailing) {
                            Text(AppL("收起"))
                                .opacity(panelExpanded ? 1 : 0)
                                .accessibilityHidden(!panelExpanded)
                            Text(AppL("展开"))
                                .opacity(panelExpanded ? 0 : 1)
                                .accessibilityHidden(panelExpanded)
                        }
                        .transaction { $0.animation = nil }
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(panelExpanded ? 0 : 180))
                    }
                    .font(.caption)
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .frame(height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width),
                      abs(value.translation.height) > 25 else { return }
                togglePanel(value.translation.height < 0)
            })
            .accessibilityLabel(AppL(panelExpanded ? "收起调整面板" : "展开调整面板"))

            ScrollView {
                VStack(spacing: 18) {
                    importControls
                    textControls
                    if !editor.design.layers.isEmpty { layerList }
                    selectedControls
                }
                .padding(.horizontal, 16)
                .padding(.bottom, bottomInset + 20)
            }
            .frame(height: max(0, height - 60))
            .scrollDismissesKeyboard(.interactively)
            .opacity(panelExpanded ? 1 : 0)
            .allowsHitTesting(panelExpanded)
            .accessibilityHidden(!panelExpanded)
        }
        .frame(height: height, alignment: .top)
        .clipped()
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if let cover = editor.cover {
                    Image(uiImage: cover).resizable().frame(width: size.width, height: size.height)
                } else {
                    Text(AppL("请添加封面图"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                ForEach(editor.design.layers) { layer in
                    if let image = editor.images[layer.imageName] {
                        CardFaceDraggableLayer(layer: layer, image: image, canvas: size,
                            otherFrames: editor.design.layers.filter { $0.id != layer.id }.compactMap { other in
                                guard let otherImage = editor.images[other.imageName], other.opacity > 0 else { return nil }
                                return CardFaceDraggableLayer.bounds(layer: other, image: otherImage, canvas: size)
                            },
                            selected: editor.selectedLayer == layer.id,
                            onSelect: { editor.selectedLayer = layer.id },
                            onGuidesChanged: { alignmentGuides = $0 },
                            onMove: { x, y in
                                editor.selectedLayer = layer.id
                                editor.changeSelected { $0.x = x; $0.y = y }
                            })
                    }
                }
                Path { path in
                    if let x = alignmentGuides?.verticalGuide {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    if let y = alignmentGuides?.horizontalGuide {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "cardFaceCanvas")
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.3), lineWidth: 1).allowsHitTesting(false))
        }
        .aspectRatio(1536.0 / 969.0, contentMode: .fit)
    }

    private var importControls: some View {
        HStack(spacing: 8) {
            TextField(AppL("卡面名称"), text: $editor.design.name)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 0, maxWidth: .infinity)
                .onChange(of: editor.design.name) { _, value in
                    if value.count > 80 { editor.design.name = String(value.prefix(80)) }
                }
            Menu {
                Button(AppL("从相册选择")) { importRequest = .coverPhotos }
                Button(AppL("从文件选择")) { importRequest = .coverFiles }
            } label: { Label(AppL(editor.cover == nil ? "添加封面" : "更换封面"), systemImage: "photo") }
            .fixedSize(horizontal: true, vertical: false)
            Menu {
                Button(AppL("内置素材")) { showMaterials = true }
                Button(AppL("从相册选择")) { showLogoPhotos = true }
                Button(AppL("从文件选择")) { importRequest = .logoFiles }
            } label: { Label(AppL("添加 Logo"), systemImage: "square.on.square.badge.plus") }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.subheadline)
        .controlSize(.regular)
        .buttonStyle(.bordered)
    }

    private var textControls: some View {
        HStack(spacing: 8) {
            TextField(AppL("自定义文字（最多30字符）"), text: $customText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: customText) { _, value in
                    if value.count > 30 { customText = String(value.prefix(30)) }
                }
            Button(AppL("添加文字")) {
                pendingLayerRemoval = nil
                let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    toast = AppToast(message: "请先输入需要添加的文字内容")
                    return
                }
                editor.addText(text)
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var layerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppL("图层")).font(.subheadline.bold())
            Text(AppL("从左到右为图层显示优先级，长按图层块，可左右拖动排序")).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(editor.design.layers) { layer in
                        Button {
                            pendingLayerRemoval = nil
                            editor.selectedLayer = layer.id
                        } label: {
                            Group {
                                if pendingLayerRemoval == layer.id && !reduceMotion {
                                    Text(layer.title).lineLimit(1)
                                        .phaseAnimator([-2.0, 2.0]) { content, angle in
                                            content.rotationEffect(.degrees(angle))
                                        } animation: { _ in
                                            .easeInOut(duration: 0.12)
                                        }
                                } else {
                                    Text(layer.title).lineLimit(1)
                                }
                            }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(editor.selectedLayer == layer.id ? Color.blue.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .dropDestination(for: String.self) { items, _ in
                            guard items.count == 1, let id = UUID(uuidString: items[0]) else { return false }
                            var moved = false
                            withAnimation(.easeInOut(duration: 0.18)) {
                                moved = editor.moveLayer(id: id, to: layer.id)
                            }
                            dropTarget = nil
                            pendingLayerRemoval = nil
                            return moved
                        } isTargeted: { targeted in
                            if targeted { dropTarget = layer.id }
                            else if dropTarget == layer.id { dropTarget = nil }
                        }
                        .overlay(Capsule().stroke(dropTarget == layer.id ? Color.blue : Color.clear, lineWidth: 2).allowsHitTesting(false))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                if pendingLayerRemoval == layer.id {
                                    pendingLayerRemoval = nil
                                    editor.removeLayer(id: layer.id)
                                } else {
                                    pendingLayerRemoval = layer.id
                                }
                            } label: {
                                Image(systemName: pendingLayerRemoval == layer.id ? "checkmark" : "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(.red, in: Circle())
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: LayerRemovalButtonFrames.self,
                                        value: [layer.id: geometry.frame(in: .named("cardFaceEditor"))])
                                }
                            }
                            .offset(x: 8, y: -8)
                            .accessibilityLabel(AppL(pendingLayerRemoval == layer.id ? "确认移除\(layer.title)" : "准备移除\(layer.title)"))
                            .accessibilityHint(AppL(pendingLayerRemoval == layer.id ? "点击确认删除，点击其他位置可取消" : "点击后进入删除确认状态"))
                        }
                        // Use the complete chip, including its background and badge, as the drag preview.
                        .contentShape(.dragPreview, Capsule())
                        .draggable(layer.id.uuidString)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectedControls: some View {
        if let layer = editor.design.layers.first(where: { $0.id == editor.selectedLayer }) {
            VStack(spacing: 14) {
                HStack {
                    Text(AppL("大小"))
                    Slider(value: Binding(get: { layer.width }, set: { value in editor.changeSelected { $0.width = value } }), in: 0.05...0.85)
                    Text(AppL("\(Int((layer.width * 100).rounded()))%"))
                        .font(.caption.monospacedDigit()).frame(width: 42)
                }
                HStack {
                    Text(AppL("旋转"))
                    Slider(value: Binding(get: { layer.rotation }, set: { value in editor.changeSelected { $0.rotation = value } }), in: -180...180)
                    Text(AppL("\(Int(layer.rotation))°")).font(.caption.monospacedDigit()).frame(width: 42)
                }
                HStack {
                    Text(AppL("透明度"))
                    Slider(value: Binding(get: { 1 - layer.opacity }, set: { value in editor.changeSelected { $0.opacity = 1 - value } }), in: 0...1)
                    Text(AppL("\(Int(((1 - layer.opacity) * 100).rounded()))%"))
                        .font(.caption.monospacedDigit()).frame(width: 42)
                }
                if layer.text != nil {
                    HStack(spacing: 6) {
                        textStyleButton("粗体", icon: "bold", selected: layer.textBold, keyPath: \.textBold)
                        textStyleButton("斜体", icon: "italic", selected: layer.textItalic, keyPath: \.textItalic)
                        Button {
                            pendingLayerRemoval = nil
                            fontLayer = layer.id
                        } label: {
                            Text(layer.textFontID == nil ? AppL("更换字体") : (fonts.availableFont(layer.textFontID)?.name ?? AppL("字体不存在！")))
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            if layer.text != nil {
                CardFaceTextColorControls(layer: layer, panelExpanded: panelExpanded, onChange: { red, green, blue in
                    pendingLayerRemoval = nil
                    editor.setTextColor(id: layer.id, red: red, green: green, blue: blue)
                }, onToast: { message in
                    toast = AppToast(message: message)
                })
                .id(layer.id)
            }
        }
    }

    private func textStyleButton(_ title: String, icon: String, selected: Bool,
                                 keyPath: WritableKeyPath<CardFaceLayer, Bool>) -> some View {
        Button {
            pendingLayerRemoval = nil
            editor.toggleTextStyle(keyPath)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(AppL(title))
            }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.blue : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(AppL(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(AppL(selected ? "已开启" : "已关闭"))
    }

    private func save() {
        guard let cover = editor.cover else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                var design = editor.design
                design.name = design.name.trimmingCharacters(in: .whitespacesAndNewlines)
                try await store.save(design, cover: cover, images: editor.images)
                dismiss()
            } catch { editor.errorMessage = error.localizedDescription }
        }
    }
}

private struct CardFaceTextColorControls: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let layer: CardFaceLayer
    let panelExpanded: Bool
    @State private var colorEditing = false
    let onChange: (Double, Double, Double) -> Void
    let onToast: (String) -> Void
    @State private var hex = ""
    @State private var hsv = CardFaceHSV(hue: 0, saturation: 0, brightness: 1)
    @State private var colorToReveal: String?
    @State private var scrollRequest = UUID()
    @AppStorage("aircard.textCustomColors") private var customColorData = Data()
    @FocusState private var editingHex: Bool
    private let presets = ["#FFFFFF", "#000000", "#FF3B30", "#FFCC00", "#34C759", "#007AFF", "#AF52DE"]

    private var color: Color { Color(red: layer.textRed, green: layer.textGreen, blue: layer.textBlue) }

    private var customColors: [String] {
        let saved = (try? JSONDecoder().decode([String].self, from: customColorData)) ?? []
        var seen = Set(presets)
        return saved.compactMap { value in
            var parsed = layer
            guard parsed.setTextColor(hex: value), seen.insert(parsed.textColorHex).inserted else { return nil }
            return parsed.textColorHex
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 6) {
                    Text(AppL("字体颜色"))
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    Text(AppL("双击 · 进入／退出面板调色模式"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "paintpalette.fill")
                        .font(.subheadline)
                        .foregroundStyle(colorEditing ? Color.blue : Color.gray)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(AppL(colorEditing ? "调色模式已开启" : "调色模式已关闭"))
                .accessibilityAction { toggleColorEditing() }
                saturationBrightnessArea
                hueBar
            }
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture(count: 2).onEnded { toggleColorEditing() })
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                TextField(AppL("#FFFFFF"), text: $hex)
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingHex)
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit(applyHex)
                    .onChange(of: hex) { _, value in
                        guard editingHex else { return }
                        var updated = layer
                        guard updated.setTextColor(hex: value) else { return }
                        hsv = CardFaceHSV(red: updated.textRed, green: updated.textGreen, blue: updated.textBlue, fallbackHue: hsv.hue)
                        onChange(updated.textRed, updated.textGreen, updated.textBlue)
                    }
                Button(AppL("添加自定义颜色"), action: addCustomColor)
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presets + customColors, id: \.self) { value in
                            let preset = presetLayer(value)
                            Button {
                                editingHex = false
                                selectColor(preset)
                            } label: {
                                Circle()
                                    .fill(Color(red: preset.textRed, green: preset.textGreen, blue: preset.textBlue))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                                    .padding(3)
                                    .overlay(Circle().stroke(layer.textColorHex == value ? Color.blue : Color.clear, lineWidth: 2))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !presets.contains(value) {
                                    Button(role: .destructive) {
                                        deleteCustomColor(value)
                                    } label: {
                                        Label(AppL("删除"), systemImage: "trash")
                                    }
                                }
                            }
                            .accessibilityLabel(AppL("字体颜色 \(value)"))
                            .accessibilityAddTraits(layer.textColorHex == value ? .isSelected : [])
                            .id(value)
                        }
                    }
                }
                .task(id: scrollRequest) {
                    guard let value = colorToReveal else { return }
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { syncColor() }
        .onChange(of: layer.textColorHex) { _, _ in syncColor() }
        .onChange(of: panelExpanded) { _, expanded in
            if !expanded { colorEditing = false }
        }
    }

    private func toggleColorEditing() {
        editingHex = false
        colorEditing.toggle()
    }

    private var saturationBrightnessArea: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(hue: hsv.hue, saturation: 1, brightness: 1)
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: size.width, height: size.height)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous),
                       style: FillStyle(antialiased: true))
            .overlay {
                Circle().stroke(.white, lineWidth: 2)
                    .background(Circle().fill(color))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(width: 16, height: 16)
                    .position(x: min(max(8, hsv.saturation * size.width), max(8, size.width - 8)),
                              y: min(max(8, (1 - hsv.brightness) * size.height), max(8, size.height - 8)))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard colorEditing, size.width > 0, size.height > 0 else { return }
                hsv.saturation = min(1, max(0, value.location.x / size.width))
                hsv.brightness = 1 - min(1, max(0, value.location.y / size.height))
                applyHSV()
            }, including: colorEditing ? .all : .none)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppL("饱和度与明暗"))
            .accessibilityValue(AppL("饱和度 \(Int(hsv.saturation * 100))%，明暗 \(Int(hsv.brightness * 100))%"))
        }
        .frame(height: 180)
        // Sliders also make both axes independently available to VoiceOver.
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { hsv.saturation }, set: { hsv.saturation = $0; applyHSV() }), in: 0...1) {
                    Text(AppL("饱和度"))
                }
                Slider(value: Binding(get: { hsv.brightness }, set: { hsv.brightness = $0; applyHSV() }), in: 0...1) {
                    Text(AppL("明暗"))
                }
            }
            .disabled(!colorEditing)
        }
    }

    private var hueBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
                .clipShape(Capsule())
                .frame(height: 18)
                .overlay {
                    Circle().stroke(.white, lineWidth: 2)
                        .background(Circle().fill(Color(hue: hsv.hue, saturation: 1, brightness: 1)))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(width: 16, height: 16)
                        .position(x: min(max(8, hsv.hue * width), max(8, width - 8)), y: 9)
                        .allowsHitTesting(false)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    guard colorEditing, width > 0 else { return }
                    hsv.hue = min(1, max(0, value.location.x / width))
                    applyHSV()
                }, including: colorEditing ? .all : .none)
        }
        .frame(height: 32)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { hsv.hue }, set: { hsv.hue = $0; applyHSV() }), in: 0...1) {
                Text(AppL("色相"))
            }
            .disabled(!colorEditing)
        }
    }

    private func applyHSV() {
        editingHex = false
        let rgb = hsv.rgb
        var updated = layer
        updated.textRed = rgb.red; updated.textGreen = rgb.green; updated.textBlue = rgb.blue
        hex = updated.textColorHex
        onChange(rgb.red, rgb.green, rgb.blue)
    }

    private func syncColor() {
        hex = layer.textColorHex
        // Keep the user's HSV coordinates when they already produce the current RGB,
        // including the red endpoint and hue/saturation choices while brightness is zero.
        let rgb = hsv.rgb
        if rgb.red != layer.textRed || rgb.green != layer.textGreen || rgb.blue != layer.textBlue {
            hsv = CardFaceHSV(red: layer.textRed, green: layer.textGreen, blue: layer.textBlue, fallbackHue: hsv.hue)
        }
    }

    private func selectColor(_ parsed: CardFaceLayer) {
        hsv = CardFaceHSV(red: parsed.textRed, green: parsed.textGreen, blue: parsed.textBlue, fallbackHue: hsv.hue)
        hex = parsed.textColorHex
        onChange(parsed.textRed, parsed.textGreen, parsed.textBlue)
    }

    private func presetLayer(_ value: String) -> CardFaceLayer {
        var preset = layer
        preset.setTextColor(hex: value)
        return preset
    }

    private func applyHex() {
        var updated = layer
        guard updated.setTextColor(hex: hex) else { onToast("请输入6位十六进制色值，例如 #2A1E3A"); return }
        editingHex = false
        selectColor(updated)
    }

    private func deleteCustomColor(_ value: String) {
        guard !presets.contains(value),
              let data = try? JSONEncoder().encode(customColors.filter { $0 != value }) else { return }
        customColorData = data
        if colorToReveal == value { colorToReveal = nil }
    }

    private func addCustomColor() {
        var updated = layer
        guard updated.setTextColor(hex: hex) else { onToast("请输入6位十六进制色值，例如 #2A1E3A"); return }
        let value = updated.textColorHex
        if (presets + customColors).contains(value) {
            onToast("该颜色已存在")
        } else {
            guard let data = try? JSONEncoder().encode(customColors + [value]) else { return }
            customColorData = data
        }
        editingHex = false
        selectColor(updated)
        colorToReveal = value
        scrollRequest = UUID()
    }
}

private struct CardFaceDraggableLayer: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let layer: CardFaceLayer
    let image: UIImage
    let canvas: CGSize
    let otherFrames: [CGRect]
    let selected: Bool
    let onSelect: () -> Void
    let onGuidesChanged: (CardFaceAlignment.Result?) -> Void
    let onMove: (Double, Double) -> Void
    @GestureState private var translation: CGSize?

    static func bounds(layer: CardFaceLayer, image: UIImage, canvas: CGSize) -> CGRect {
        let width = canvas.width * layer.width
        let height = width * image.size.height / max(image.size.width, 1)
        let angle = layer.rotation * .pi / 180
        let rotatedWidth = abs(cos(angle)) * width + abs(sin(angle)) * height
        let rotatedHeight = abs(sin(angle)) * width + abs(cos(angle)) * height
        return CGRect(x: canvas.width * layer.x - rotatedWidth / 2,
                      y: canvas.height * layer.y - rotatedHeight / 2,
                      width: rotatedWidth, height: rotatedHeight)
    }

    private func alignedPosition(for delta: CGSize) -> CardFaceAlignment.Result {
        let frame = Self.bounds(layer: layer, image: image, canvas: canvas)
        return CardFaceAlignment.snap(
            center: CGPoint(x: canvas.width * layer.x + delta.width, y: canvas.height * layer.y + delta.height),
            halfSize: CGSize(width: frame.width / 2, height: frame.height / 2),
            canvas: canvas, otherFrames: otherFrames)
    }

    var body: some View {
        let width = canvas.width * layer.width
        let height = width * image.size.height / max(image.size.width, 1)
        let center = translation.map { alignedPosition(for: $0).center }
            ?? CGPoint(x: canvas.width * layer.x, y: canvas.height * layer.y)
        Image(uiImage: image).resizable().scaledToFit()
            .opacity(layer.opacity)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(selected ? Color.white : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false))
            .rotationEffect(.degrees(layer.rotation))
            .position(center)
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cardFaceCanvas"))
                .updating($translation) { value, state, _ in state = value.translation }
                .onChanged { value in
                    onSelect()
                    onGuidesChanged(alignedPosition(for: value.translation))
                }
                .onEnded { value in
                    guard canvas.width > 0, canvas.height > 0 else { return }
                    let result = alignedPosition(for: value.translation)
                    onMove(result.center.x / canvas.width, result.center.y / canvas.height)
                    onGuidesChanged(nil)
                })
            .onChange(of: translation) { _, value in
                if value == nil { onGuidesChanged(nil) }
            }
            .accessibilityLabel(layer.title)
            .accessibilityHint(AppL("轻点选中，拖动调整位置"))
    }
}

private struct CardFaceMaterialPicker: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let onUse: (UIImage, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private func thumbnailBackground(for material: CardFaceMaterial) -> Color {
        let usesDarkBackground = material.id == "MaterialBeijingTransit"
            || material.id == "MaterialVisaSilver"
            || (material.id == "MaterialVisaTone" && colorScheme == .dark)
        return usesDarkBackground
            ? Color(red: 72.0 / 255, green: 72.0 / 255, blue: 79.0 / 255)
            : Color(red: 229.0 / 255, green: 229.0 / 255, blue: 234.0 / 255)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(["银行标识", "交通标识", "卡组织标识", "品牌标识"], id: \.self) { category in
                    Section(AppL(category)) {
                        ForEach(CardFaceMaterial.all.filter { $0.category == category }) { material in
                            Button {
                                guard let image = UIImage(named: material.id) else { return }
                                onUse(image, material.name)
                                dismiss()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(material.id).resizable().scaledToFit()
                                        .frame(width: 100, height: 48)
                                        .padding(6)
                                        .background(thumbnailBackground(for: material), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(Color(uiColor: .systemGray3), lineWidth: 1)
                                        }
                                    Text(AppL(material.name)).foregroundStyle(.primary)
                                }
                            }
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                        }
                    }
                }
            }
            .navigationTitle(AppL("内置素材"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppL("关闭")) { dismiss() } } }
        }
    }
}
