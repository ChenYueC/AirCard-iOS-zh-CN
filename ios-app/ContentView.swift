import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Shared helpers

// Set the icon's own tint mode so popover dimming cannot propagate from its ancestors.
private struct WalletMoreIcon: UIViewRepresentable {
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: "ellipsis.circle",
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)))
        view.contentMode = .scaleAspectFit
        view.tintAdjustmentMode = .normal
        view.tintColor = .systemBlue
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.tintAdjustmentMode = .normal
        view.tintColor = .systemBlue
    }
}

// Keep the selected tab's tint when a card action popover dims the presenting view.
private struct WalletTabBarTint: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        func preserveTabTint() {
            tabBarController?.tabBar.tintAdjustmentMode = .normal
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            preserveTabTint()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            preserveTabTint()
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.preserveTabTint()
    }
}

func logLineColor(_ line: String) -> Color {
    if line.contains("✅") || line.contains("🎉") { return .green }
    if line.contains("❌") { return .red }
    if line.contains("⚠️") { return .orange }
    return .secondary
}

// MARK: - Compact Scrollable Log View with 1-Click Copy

struct CompactLogView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let title: String
    let lines: [String]
    var onClear: (() -> Void)? = nil
    var reservedHeight: CGFloat? = nil
    var showsScrollIndicators = true
    var clearButtonShowsTitle = false
    var fillsAvailableHeight = false
    var headerHorizontalInset: CGFloat = 0
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AppL(title))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let onClear = onClear, !lines.isEmpty {
                    Button(action: onClear) {
                        if clearButtonShowsTitle {
                            Label(AppL("清空"), systemImage: "trash")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(Capsule())
                        } else {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, clearButtonShowsTitle ? 0 : 6)
                }
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        copied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        var t2 = Transaction()
                        t2.disablesAnimations = true
                        withTransaction(t2) {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                        Text(AppL(copied ? "已复制" : "复制"))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(copied ? .green : .blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.borderless)
                .transaction { $0.animation = nil }
            }
            .padding(.horizontal, headerHorizontalInset)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(AppL(line))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(logLineColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(showsScrollIndicators ? .visible : .hidden)
                .frame(height: reservedHeight)
                .frame(maxHeight: fillsAvailableHeight ? .infinity : (reservedHeight ?? 180))
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if lines.isEmpty {
                        Text(AppL("暂无日志"))
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .onChange(of: lines.count) { _, _ in
                    if !lines.isEmpty {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Native Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let shouldStop = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStop { url.stopAccessingSecurityScopedResource() }
            }
            parent.onPick(url)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Root Tab View

struct ContentView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var cardFaceLibrary = CardFaceLibraryStore()

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            PairingTab()
                .tabItem { Label(AppL("配对"), systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.pairing)

            WalletCardsTab()
                .background(WalletTabBarTint().frame(width: 0, height: 0))
                .tabItem { Label(AppL("钱包卡片"), systemImage: "creditcard.fill") }
                .tag(AppTab.walletCards)

            CardFaceLibraryView()
                .tabItem { Label(AppL("卡面资源库"), systemImage: "rectangle.stack.fill") }
                .tag(AppTab.cardFaceLibrary)

        }
        .environmentObject(cardFaceLibrary)
        .alert(AppL("提示"), isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button(AppL("确定")) { vm.errorMessage = nil }
        } message: {
            Text(AppL(vm.errorMessage ?? ""))
        }
        .alert(AppL("成功！🎉"), isPresented: $vm.showSuccessAlert) {
            Button(AppL("确定")) {}
        } message: {
            Text(AppL(vm.successAlertMessage))
        }
        .onAppear {
            vm.showSuccessAlert = false
            vm.successAlertMessage = ""
        }
    }
}

// MARK: - Pairing Tab

private struct PairingContentLayout: Layout {
    let availableHeight: CGFloat
    private let spacing: CGFloat = 12
    private let minimumLogHeight: CGFloat = 160

    init(availableHeight: CGFloat) {
        self.availableHeight = availableHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 0
        let upperHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: max(availableHeight, upperHeight + spacing + minimumLogHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let upperHeight = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: upperHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + upperHeight + spacing),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width,
                                                     height: max(minimumLogHeight, bounds.height - upperHeight - spacing)))
    }
}

struct PairingTab: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var vpn = LoopbackVPNManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFilePicker = false
    @State private var showAbout = false
    @State private var pairingSwipeOffset: CGFloat = 0
    @State private var pairingDeleteVisible = false
    @ScaledMetric(relativeTo: .body) private var pairingRowHeight: CGFloat = 64

    private var isIOS27OrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    PairingContentLayout(availableHeight: max(0, geometry.size.height - 24)) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                pairingSectionTitle("关于")
                                headerSection
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                pairingSectionTitle("网络")
                                VPNStatusRow(vm: vm)
                                    .padding(14)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            pairingFileSection
                            onDevicePairingSection
                        }

                        CompactLogView(
                            title: "活动日志（\(vm.log.count) 行）",
                            lines: vm.log,
                            onClear: { vm.log.removeAll() },
                            showsScrollIndicators: true,
                            clearButtonShowsTitle: true,
                            fillsAvailableHeight: true,
                            headerHorizontalInset: 14
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollIndicators(.hidden)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppL("AirCard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    vpnCapsule
                }
            }
            .onChange(of: vpn.errorMessage) { _, message in
                if let message { vm.errorMessage = message }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await vpn.reload() }
                    vm.refreshPairingFile()
                    vm.refreshNetworkStatus()
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPickerView(allowedContentTypes: [
                    UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                    UTType(filenameExtension: "plist") ?? .propertyList,
                    UTType(filenameExtension: "mobilepair") ?? .data,
                    .propertyList,
                    .data,
                    .item
                ]) { url in
                    _ = vm.importPairingFile(from: url, originalName: url.lastPathComponent)
                }
            }
            .sheet(isPresented: $showAbout) {
                AirCardAboutView()
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(26)
            }
            .onAppear {
                vm.refreshNetworkStatus()
                vm.refreshPairingFile()
            }
        }
    }
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showAbout = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text(AppL("AirCard"))
                        .font(.title2.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(AppL("利用airtraffic，在本机自定义钱包卡面"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppL("打开关于 AirCard"))
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pairingSectionTitle(_ title: String) -> some View {
        Text(AppL(title))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
    }

    private var pairingFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            pairingSectionTitle("配对文件")
            ZStack(alignment: .trailing) {
                Button(role: .destructive) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        vm.deletePairingFile()
                        pairingDeleteVisible = false
                        pairingSwipeOffset = 0
                    }
                } label: {
                    Text(AppL("删除"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: pairingRowHeight)
                        .background(Color.red)
                }
                .buttonStyle(.plain)
                .disabled(!vm.hasPairingFile || vm.cardOperationRunning)
                .accessibilityHidden(!pairingDeleteVisible)

                pairingFileRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: pairingRowHeight)
                    .padding(.horizontal, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .contentShape(Rectangle())
                    .offset(x: pairingSwipeOffset)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                guard vm.hasPairingFile, !vm.cardOperationRunning,
                                      abs(value.translation.width) > abs(value.translation.height) else { return }
                                let origin: CGFloat = pairingDeleteVisible ? -76 : 0
                                pairingSwipeOffset = min(0, max(-76, origin + value.translation.width))
                            }
                            .onEnded { _ in
                                pairingDeleteVisible = vm.hasPairingFile && pairingSwipeOffset < -38
                                withAnimation(.easeOut(duration: 0.18)) {
                                    pairingSwipeOffset = pairingDeleteVisible ? -76 : 0
                                }
                            }
                    )
            }
            .frame(height: pairingRowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: vm.pairingFileName) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pairingDeleteVisible = false
                    pairingSwipeOffset = 0
                }
            }
            .accessibilityAction(named: Text(AppL("显示删除按钮"))) {
                guard vm.hasPairingFile, !vm.cardOperationRunning else { return }
                pairingDeleteVisible = true
                pairingSwipeOffset = -76
            }
            Text(AppL(vm.hasPairingFile
                 ? "已选择配对文件，可左滑删除后重新选择"
                 : "如无配对文件，可使用jitterbugpair生成配对文件"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var pairingFileRow: some View {
        if vm.hasPairingFile {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text((vm.pairingFileName as NSString).deletingPathExtension)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AppL("当前使用 · \(vm.pairingFileSizeString)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button { showFilePicker = true } label: {
                HStack {
                    Label(AppL("选择本机的配对文件"), systemImage: "doc.badge.plus")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.cardOperationRunning)
        }
    }

    @ViewBuilder
    private var onDevicePairingSection: some View {
        // On-Device Pairing Section (AppL(shown ONLY on iOS 27+))
        if isIOS27OrNewer {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppL("在此 iPhone 上配对"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if vm.pairingPhase == .pairing {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.85)
                            Text(AppL(vm.pairingStatus.isEmpty ? "正在启动本地配对服务…" : vm.pairingStatus))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let pin = vm.pairingPIN {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(AppL("在此 iPhone 上输入以下 PIN 码："))
                                    .font(.caption2.bold().uppercaseSmallCaps())
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .center, spacing: 0) {
                                    Text(pin)
                                        .font(.system(size: 40, weight: .black, design: .monospaced))
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = pin
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    } label: {
                                        Label(AppL("复制"), systemImage: "doc.on.doc")
                                            .font(.caption.bold())
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                }

                                Text(AppL("设置 › 隐私与安全性 › 开发者模式 › 与 AirCard 配对"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Button {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    Label(AppL("打开“设置”应用"), systemImage: "arrow.up.forward.app")
                                        .bold()
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                            .padding(14)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(role: .cancel) {
                            vm.cancelPairing()
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "xmark")
                                Text(AppL("取消配对"))
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } else {
                    VStack(spacing: 12) {
                        if !vm.pairingStatus.isEmpty && vm.pairingStatus != "idle" {
                            Text(AppL(vm.pairingStatus))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(
                                    vm.pairingStatus.contains("✅") ? .green :
                                    vm.pairingStatus.contains("❌") || vm.pairingStatus.contains("失败") ? .red :
                                    .secondary
                                )
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        Button {
                            vm.startPairing()
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.body.weight(.semibold))
                                Text(AppL(vm.hasPairingFile ? "重新配对此 iPhone" : "配对此 iPhone"))
                                    .font(.headline)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var vpnCapsule: some View {
        Button {
            Task { await vpn.toggle() }
        } label: {
            HStack(spacing: 6) {
                if vpn.isTransitioning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: vpn.isConnected ? "checkmark.shield.fill" : "shield")
                }
                Text(AppL(vpn.label))
                    .font(.caption.weight(.semibold))
                Circle()
                    .fill(vpn.isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(vpn.isConnected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vpn.isTransitioning)
        .accessibilityLabel(AppL("内置回环 VPN"))
        .accessibilityValue(AppL(vpn.label))
        .accessibilityHint(AppL(vpn.isConnected ? "轻点断开" : "轻点连接"))
    }

}

// MARK: - VPN Status Row

struct VPNStatusRow: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var vpn = LoopbackVPNManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(AppL(vm.vpnUp ? "VPN 已连接" : "VPN 未连接"),
                      systemImage: vm.vpnUp ? "checkmark.shield.fill" : "shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(vm.vpnUp ? .green : .secondary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(AppL("设备地址：\(vm.deviceIP) · \(vpn.isConnected ? "内置回环 VPN 已连接" : (vm.vpnUp ? "已检测到外部回环 VPN" : "可使用右上角开关或外部回环 VPN 连接"))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppL("回环实现基于 LocalDevVPN / StosVPN"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Apple Wallet Card View Component (Authentic AirCard Style)

struct WalletCardView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let card: CardItem
    let cardIndex: Int
    let originalImage: UIImage?
    let isLoadingOriginal: Bool
    let onToggleSelected: (Bool) -> Void
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let hasBeenReplaced: Bool
    let onRemove: () -> Void
    let onRestoreAndDelete: () -> Void
    let onRename: (String) -> Void
    let canRestore: Bool
    let isRestoring: Bool
    let operationsDisabled: Bool

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showCardMenu = false
    @State private var pendingCardMenuAction: CardMenuAction?
    private enum CardMenuAction { case clearImage, remove, restore, rename }

    var body: some View {
        VStack(spacing: 10) {
            // Realistic Apple Wallet Card Mockup (1.586 : 1 aspect ratio)
            GeometryReader { geo in
                let width = geo.size.width
                let height = width / 1.586

                ZStack {
                    if let img = card.uiImage {
                        // Custom skin applied
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            // Subtle Apple Wallet Card Gloss Overlay
                            LinearGradient(
                                colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        }
                    } else {
                        // Empty / Placeholder Card Mockup
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(uiColor: .secondarySystemBackground),
                                            Color(uiColor: .tertiarySystemBackground)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            if originalImage == nil {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            }

                            if let originalImage {
                                Image(uiImage: originalImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .antialiased(true)
                                    .scaledToFill()
                                    .frame(width: width, height: height)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.black.opacity(0.35))
                            }

                            // Contactless & Chip icons
                            VStack(alignment: .leading) {
                                HStack {
                                    Image(systemName: "wave.3.right")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                    Spacer()
                                }
                                .padding(14)
                                Spacer()
                            }

                            // Center Action Callout
                            VStack(spacing: 8) {
                                if isLoadingOriginal {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text(AppL("卡片预览图加载中…"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 32))
                                        .foregroundStyle(originalImage == nil ? Color.blue : Color.white)
                                }

                                Text(AppL("设置卡面"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(originalImage == nil ? Color.primary : Color.white)

                                Text(AppL("点击选择照片"))
                                    .font(.caption2)
                                    .foregroundStyle(originalImage == nil ? Color.secondary : Color.white.opacity(0.85))
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !operationsDisabled else { return }
                    onPickImage()
                }
                .overlay(alignment: .topTrailing) {
                    Button { showCardMenu = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.35), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppL("卡片操作"))
                    .popover(isPresented: $showCardMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                        cardMenu
                            .presentationCompactAdaptation(.popover)
                            .presentationBackground(.ultraThinMaterial)
                            .onDisappear { performPendingCardMenuAction() }
                    }
                    .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasBeenReplaced {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.system(size: 24, weight: .semibold))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(12)
                            .allowsHitTesting(false)
                            .accessibilityLabel(AppL("卡面已替换"))
                    }
                }
            }
            .aspectRatio(1.586, contentMode: .fit)

            // Card Controls & Meta Bar
            HStack(spacing: 8) {
                Button {
                    onToggleSelected(!card.isSelected)
                } label: {
                    Image(systemName: card.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(card.isSelected ? Color.blue : Color.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppL("选择卡片参与应用"))
                .accessibilityValue(AppL(card.isSelected ? "已选中" : "未选中"))

                Text(card.name ?? AppL("卡片 #\(cardIndex + 1)"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Text(card.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .systemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
        .overlay {
            if isRestoring {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(AppL("正在恢复原始卡面…")).font(.subheadline)
                    }
                }
            }
        }
        .disabled(operationsDisabled)
        .alert(AppL("重命名卡片"), isPresented: $showRename) {
            TextField(AppL("卡片名称（最多 5 个字符）"), text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(AppL("取消"), role: .cancel) { }
            Button(AppL("保存")) { onRename(renameText) }
                .disabled(CardItem.cleanName(renameText) == nil || operationsDisabled)
        } message: {
            Text(AppL("名称限 1 到 5 个字符，仅用于 AirCard 内显示。"))
        }
    }
    private var cardMenu: some View {
        VStack(spacing: 0) {
            cardMenuButton("清除已选图片", icon: "xmark", action: .clearImage,
                           enabled: card.customImage != nil || card.customImageData != nil)
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5).padding(.horizontal, 12)
            cardMenuButton("移除卡片", icon: "minus.circle", action: .remove, destructive: true)
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5).padding(.horizontal, 12)
            cardMenuButton("移除并恢复卡片", icon: "arrow.counterclockwise.circle", action: .restore,
                           enabled: canRestore, destructive: true)
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5).padding(.horizontal, 12)
            cardMenuButton("重命名", icon: "pencil", action: .rename)
        }
        .frame(width: 240)
        .padding(.vertical, 4)
    }

    private func cardMenuButton(_ title: String, icon: String, action: CardMenuAction,
                                enabled: Bool = true, destructive: Bool = false) -> some View {
        Button {
            pendingCardMenuAction = action
            showCardMenu = false
        } label: {
            HStack {
                Text(AppL(title))
                Spacer()
                Image(systemName: icon)
            }
            .font(.subheadline)
            .foregroundStyle(enabled ? (destructive ? Color.red : Color.primary) : Color.secondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || operationsDisabled)
    }

    private func performPendingCardMenuAction() {
        guard let action = pendingCardMenuAction else { return }
        pendingCardMenuAction = nil
        DispatchQueue.main.async {
            switch action {
            case .clearImage: onClearImage()
            case .remove: onRemove()
            case .restore: onRestoreAndDelete()
            case .rename:
                renameText = card.name ?? ""
                showRename = true
            }
        }
    }

}

// MARK: - Wallet Cards Tab

struct WalletCardsTab: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var vm: AppViewModel
    @State private var newHashText = ""
    @State private var showAddSheet = false
    @State private var cardPendingDelete: CardItem?
    @State private var showDeleteConfirmation = false
    @State private var showSelectedRestoreConfirmation = false
    private struct CardDragState: Equatable {
        let id: String
        let translation: CGFloat
    }
    @GestureState private var cardDrag: CardDragState?
    @State private var cardFrames: [String: CGRect] = [:]
    enum ActiveCardPicker: Identifiable {
        case singleCard(String)
        case bulkSelected
        var id: String {
            switch self {
            case .singleCard(let id): return id
            case .bulkSelected: return "bulk_selected"
            }
        }
    }
    @State private var activePicker: ActiveCardPicker? = nil
    @State private var showSourceDialog: Bool = false
    @State private var isPhotosPickerPresented: Bool = false
    @State private var isDocumentPickerPresented: Bool = false
    @State private var isCardFaceLibraryPresented = false
    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
        let target: ActiveCardPicker
    }
    @State private var pendingCrop: CropRequest?
    @State private var cropRequest: CropRequest?
    @State private var photoLoadFailed = false
    @State private var pendingLoadError = false
    @State private var cropAccepted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    scannerBanner

                    if vm.cards.isEmpty {
                        walletEmptyState
                            .padding(.top, 40)
                    } else {
                        cardsList
                    }
                }
                .padding(.vertical)
                .transaction { $0.animation = nil }
            }
            .transaction { $0.animation = nil }
            .scrollDisabled(cardDrag != nil)
            .onChange(of: cardDrag?.id) { _, id in
                if id != nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppL("钱包卡片（\(vm.cards.count)）"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.toggleCardScanning()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vm.isScanningCards ? "stop.circle.fill" : "wave.3.left.circle")
                            Text(AppL(vm.isStoppingCardScan ? "停止扫描中" : (vm.isScanningCards ? "停止扫描" : "扫描卡片")))
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(vm.isScanningCards ? .red : .blue)
                    }
                    .disabled(vm.isStoppingCardScan)
                    .transaction { $0.animation = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label(AppL("手动添加卡片"), systemImage: "plus")
                        }
                        if !vm.cards.isEmpty {
                            Button {
                                activePicker = .bulkSelected
                                showSourceDialog = true
                            } label: {
                                Label(AppL("为所选卡片设置卡面…"), systemImage: "photo.on.rectangle.angled")
                            }
                            .disabled(vm.selectedCards.isEmpty || vm.cardOperationRunning)

                            Divider()

                            Button {
                                vm.selectAllCards(true)
                            } label: {
                                Label(AppL("全选"), systemImage: "checkmark.circle")
                            }

                            Button {
                                vm.selectAllCards(false)
                            } label: {
                                Label(AppL("取消全选"), systemImage: "circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    vm.removeSelectedCards()
                                }
                            } label: {
                                Label(AppL("移除所选卡片"), systemImage: "trash")
                            }
                            .disabled(vm.selectedCards.isEmpty || vm.cardOperationRunning)

                            Button(role: .destructive) {
                                showSelectedRestoreConfirmation = true
                            } label: {
                                Label(AppL("删除并恢复所选卡片"), systemImage: "arrow.counterclockwise.circle")
                            }
                            .disabled(!vm.canRestoreSelectedCards)
                        }
                    } label: {
                        WalletMoreIcon()
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel(AppL("更多"))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    flashButton
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddCardSheet(hashText: $newHashText) {
                    vm.addCardHash(newHashText)
                    newHashText = ""
                    showAddSheet = false
                }
            }
            .alert(AppL("移除并恢复卡片？"), isPresented: $showDeleteConfirmation) {
                Button(AppL("取消"), role: .cancel) { cardPendingDelete = nil }
                Button(AppL("移除并恢复"), role: .destructive) {
                    if let card = cardPendingDelete { vm.restoreAndDeleteCard(id: card.id) }
                    cardPendingDelete = nil
                }
            } message: {
                if let card = cardPendingDelete, vm.hasOriginalCardBackup(for: card.id) {
                    Text(AppL("将恢复原始卡面，并清除该卡片在 AirCard 中的全部本地数据。"))
                } else if let card = cardPendingDelete, vm.requiresOriginalCardRecovery(for: card.id) {
                    Text(AppL("上次卡面操作中断，将先将暂存图片归位，再清除该卡片在 AirCard 中的全部本地数据。失败时保留恢复记录。"))
                } else {
                    Text(AppL("此卡片没有原始卡面备份，无法恢复。"))
                }
            }
            .alert(AppL("删除并恢复所选卡片？"), isPresented: $showSelectedRestoreConfirmation) {
                Button(AppL("取消"), role: .cancel) { }
                Button(AppL("删除并恢复"), role: .destructive) {
                    vm.restoreAndDeleteSelectedCards()
                }
            } message: {
                Text(AppL("将逐张恢复所选的 \(vm.selectedCards.count) 张卡片的原始卡面，并清除这些卡片在 AirCard 中的全部本地数据。失败时停止后续处理。"))
            }
            .confirmationDialog(AppL("选择图片来源"), isPresented: $showSourceDialog, titleVisibility: .visible) {
                Button {
                    isCardFaceLibraryPresented = true
                } label: {
                    Label(AppL("卡面资源库"), systemImage: "rectangle.stack")
                }
                Button {
                    isPhotosPickerPresented = true
                } label: {
                    Label(AppL("照片图库"), systemImage: "photo.on.rectangle")
                }
                Button {
                    isDocumentPickerPresented = true
                } label: {
                    Label(AppL("从“文件”中选择…"), systemImage: "folder")
                }
                Button(AppL("取消"), role: .cancel) {
                    activePicker = nil
                }
            }
            .sheet(isPresented: $isCardFaceLibraryPresented, onDismiss: { activePicker = nil }) {
                CardFaceLibraryView { image in
                    if let target = activePicker { assignImage(image, to: target) }
                }
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
            }
            .sheet(isPresented: $isPhotosPickerPresented, onDismiss: { activePicker = nil }) {
                if let target = activePicker {
                    CardPhotoPicker { image in
                        assignImage(image, to: target)
                    }
                }
            }
            .sheet(isPresented: $isDocumentPickerPresented, onDismiss: presentPendingCrop) {
                DocumentPickerView(allowedContentTypes: [
                    .image, .png, .jpeg, .heic,
                    UTType(filenameExtension: "webp") ?? .image,
                    UTType(filenameExtension: "tiff") ?? .image
                ]) { url in
                    guard let picker = activePicker else { return }
                    if let data = try? Data(contentsOf: url),
                       let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) {
                        pendingCrop = CropRequest(image: image, target: picker)
                    } else {
                        pendingLoadError = true
                    }
                    activePicker = nil
                }
            }
            .sheet(item: $cropRequest, onDismiss: {
                if !cropAccepted { isDocumentPickerPresented = true }
            }) { request in
                CardPhotoCropView(image: request.image) { croppedImage in
                    cropAccepted = true
                    assignImage(croppedImage, to: request.target)
                    activePicker = nil
                }
            }
            .alert(AppL("无法载入照片"), isPresented: $photoLoadFailed) {
                Button(AppL("确定"), role: .cancel) { }
            } message: {
                Text(AppL("请选择其他图片，或先将照片下载到 iPhone 后重试。"))
            }
        }
    }

    private func assignImage(_ image: UIImage, to target: ActiveCardPicker) {
        switch target {
        case .singleCard(let cardId):
            vm.setCardImage(for: cardId, image: image)
        case .bulkSelected:
            vm.setSkinForSelectedCards(image: image)
        }
    }

    private func presentPendingCrop() {
        guard !isPhotosPickerPresented, !isDocumentPickerPresented else { return }
        if let request = pendingCrop {
            pendingCrop = nil
            cropAccepted = false
            activePicker = request.target
            cropRequest = request
        } else if pendingLoadError {
            pendingLoadError = false
            photoLoadFailed = true
        }
    }

    @ViewBuilder
    private var scannerBanner: some View {
        HStack {
            if vm.isScanningCards {
                ProgressView().scaleEffect(0.85)
            } else {
                Image(systemName: "wave.3.left.circle")
                    .foregroundStyle(.secondary)
            }
            Text(AppL(vm.scanStatusText.isEmpty ? "点击扫描卡片后开始扫描" : vm.scanStatusText))
                .font(.subheadline)
                .foregroundStyle(vm.scanStatusText.contains("停止") || vm.scanStatusText.contains("出错") ? .orange : .secondary)
            Spacer()
        }
        .padding(14)
        .background(vm.isScanningCards ? Color.blue.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .transaction { $0.animation = nil }
    }

    private func walletCardRow(for card: CardItem) -> some View {
        WalletCardView(
            card: card,
            cardIndex: vm.cards.firstIndex(where: { $0.id == card.id }) ?? 0,
            originalImage: vm.originalCardPreviews[card.id],
            isLoadingOriginal: vm.loadingOriginalCardID == card.id,
            onToggleSelected: { isSelected in
                vm.setCardSelected(id: card.id, selected: isSelected)
            },
            onPickImage: {
                activePicker = .singleCard(card.id)
                showSourceDialog = true
            },
            onClearImage: { vm.clearCardImage(for: card.id) },
            hasBeenReplaced: vm.isCardFaceReplaced(for: card.id),
            onRemove: { vm.removeCard(id: card.id) },
            onRestoreAndDelete: {
                cardPendingDelete = card
                showDeleteConfirmation = true
            },
            onRename: { vm.renameCard(id: card.id, name: $0) },
            canRestore: vm.canRestoreOriginalCardFace(for: card.id),
            isRestoring: vm.restoringCardID == card.id,
            operationsDisabled: vm.cardOperationRunning
        )
    }

    private func cardDragGesture(for id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("walletCardSorting")))
            .updating($cardDrag) { value, state, _ in
                guard !vm.cardOperationRunning else { state = nil; return }
                if case .second(true, let drag) = value {
                    state = CardDragState(id: id, translation: drag?.translation.height ?? 0)
                }
            }
            .onEnded { value in
                guard case .second(true, let drag) = value, let drag,
                      abs(drag.translation.height) > 1, let sourceFrame = cardFrames[id],
                      vm.cards.allSatisfy({ cardFrames[$0.id] != nil }) else { return }
                let center = sourceFrame.midY + drag.translation.height
                let destination = vm.cards.filter { $0.id != id && (cardFrames[$0.id]?.midY ?? 0) < center }.count
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    _ = vm.moveCard(id: id, toIndex: destination)
                }
            }
    }

    @ViewBuilder
    private var cardsList: some View {
        VStack(spacing: 16) {
            ForEach(vm.cards, id: \.id) { card in
                ZStack {
                    walletCardRow(for: card)
                        .scaleEffect(cardDrag?.id == card.id ? 1.02 : 1)
                        .shadow(color: .black.opacity(cardDrag?.id == card.id ? 0.25 : 0), radius: 12, y: 8)
                        .offset(y: cardDrag?.id == card.id ? cardDrag?.translation ?? 0 : 0)
                        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: cardDrag?.id == card.id)
                        // Sorting must coexist with the card tap and its nested buttons.
                        .simultaneousGesture(cardDragGesture(for: card.id))
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("walletCardSorting"))
                } action: { frame in
                    cardFrames[card.id] = frame
                }
                .zIndex(cardDrag?.id == card.id ? 1 : 0)
                .accessibilityHint(AppL("长按抓起，上下拖动调整 AirCard 内的显示顺序"))
                .id(card.id)
            }

            if !vm.cardFlashLog.isEmpty {
                CompactLogView(
                    title: "应用日志（\(vm.cardFlashLog.count) 行）",
                    lines: vm.cardFlashLog,
                    onClear: { vm.cardFlashLog.removeAll() },
                    clearButtonShowsTitle: true
                )
                .padding(.top, 8)
            }
        }
        .padding(.horizontal)
        .coordinateSpace(name: "walletCardSorting")
    }

    @ViewBuilder
    private var flashButton: some View {
        Button {
            vm.flashCards()
        } label: {
            HStack(spacing: 4) {
                if case .running = vm.cardFlashPhase {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                    Text(AppL("应用"))
                        .font(.system(size: 13, weight: .semibold))
                } else if case .done(let ok) = vm.cardFlashPhase, !ok {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 12, height: 12)
                    Text(AppL("重试"))
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 12, height: 12)
                    Text(AppL("应用"))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(.white)
            .background(flashButtonColor.opacity(vm.canFlashCards ? 1 : 0.45), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vm.canFlashCards || vm.cardFlashPhase == .running)
        .animation(.easeInOut(duration: 0.2), value: vm.cardFlashPhase)
    }

    private var flashButtonColor: Color {
        if case .done(let ok) = vm.cardFlashPhase, !ok {
            return .orange
        }
        return .blue
    }

    private var walletEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.8))

            Text(AppL("尚未检测到卡片"))
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(AppL("1."))
                        .bold()
                        .foregroundStyle(.blue)
                    Text(LocalizedStringKey(AppL("点击上方工具栏中的**扫描卡片**。")))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text(AppL("2."))
                        .bold()
                        .foregroundStyle(.blue)
                    Text(LocalizedStringKey(AppL("在此 iPhone 上**连按两下侧边按钮**打开 Apple Pay，通过**面容 ID** 验证，然后**点击卡片**。")))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text(AppL("3."))
                        .bold()
                        .foregroundStyle(.blue)
                    Text(AppL("卡片会自动显示在这里！"))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                if !vm.isScanningCards {
                    Button {
                        vm.toggleCardScanning()
                    } label: {
                        HStack(spacing: 6) {
                            Spacer()
                            Image(systemName: "wave.3.left.circle")
                            Text(AppL("扫描卡片"))
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .transaction { $0.animation = nil }
                }

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "plus")
                        Text(AppL("手动添加"))
                        Spacer()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .transaction { $0.animation = nil }
            }
            .padding(.horizontal, 24)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Add Card Sheet

struct AddCardSheet: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @Binding var hashText: String
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(AppL("卡片哈希值")) {
                    TextField(AppL("粘贴卡片哈希值（例如 M6nDwZrkYbFl…）"), text: $hashText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(4...8)
                }
                Section {
                    Text(AppL("可同时添加多个哈希值，使用空格、逗号或换行分隔。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppL("添加卡片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(AppL("取消")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(AppL("添加")) { onAdd() }
                        .disabled(hashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .bold()
                }
            }
        }
    }
}
