import Foundation
import UIKit
import SwiftUI
import AirliftFFI
import CryptoKit

// MARK: - AppViewModel

@MainActor
final class AppViewModel: ObservableObject {

    /// Static sink for Rust log lines — set in init so AirliftApp can forward them.
    static var sharedLogSink: ((String) -> Void)? = nil
    static weak var shared: AppViewModel? = nil

    // MARK: - Pairing
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String? = nil
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPhase: PairingPhase = .idle

    enum PairingPhase: Equatable {
        case idle, pairing
    }

    // MARK: - VPN / Network
    @Published var vpnUp: Bool = false
    @Published var wifiUp: Bool = false
    @Published var networkDetail: String = ""
    @Published var deviceIP: String = "10.7.0.1" {
        didSet { syncTargetHostToRust() }
    }

    // MARK: - Tab
    @Published var selectedTab: AppTab = .pairing

    // MARK: - Wallet Cards tab
    @Published var cards: [CardItem] = []
    @Published var cardFlashPhase: FlashPhase = .idle
    @Published var cardFlashProgress: Double = 0
    @Published var cardFlashLog: [String] = []
    @Published var cardToast: AppToast?
    @Published private(set) var restoringCardID: String?
    @Published private var replacementRecords: [String: CardReplacementRecord] = [:]
    @Published private(set) var originalCardPreviews: [String: UIImage] = [:]
    @Published private(set) var loadingOriginalCardID: String?
    private var imageRequestIDs: [String: UUID] = [:]
    @Published private(set) var pendingCardImageIDs = Set<String>()
    private var originalPreviewQueue: [String] = []
    private var attemptedOriginalPreviews = Set<String>()
    private let cardKeepAlive = KeepAlive()
    var cardOperationRunning: Bool { cardFlashPhase == .running || restoringCardID != nil || loadingOriginalCardID != nil }

    enum FlashPhase: Equatable {
        case idle, running, done(ok: Bool)
    }

    @Published var showSuccessAlert: Bool = false
    @Published var successAlertMessage: String = ""

    // MARK: - Shared
    @Published var errorMessage: String? = nil
    @Published var log: [String] = []
    private let logTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let logTimestampParserWithoutFraction = ISO8601DateFormatter()
    private let logTimestampDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    @Published var showDeletePairingConfirm: Bool = false

    private let cardsStorageKey = "aircard.cards"

    init() {
        Self.shared = self
        refreshPairingFile()
        loadSavedCards()
        refreshNetworkStatus()
        syncTargetHostToRust()

        // Hook Rust log output into our log array.
        AppViewModel.sharedLogSink = { [weak self] line in
            self?.appendLog(line)
        }
    }

    @discardableResult
    func importPairingFile(from sourceURL: URL, originalName: String? = nil) -> Bool {
        guard !cardOperationRunning else {
            errorMessage = "请等待卡面操作完成后更换配对文件。"
            return false
        }
        let isSecured = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSecured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            errorMessage = "所选配对文件为空或无法读取。"
            return false
        }

        guard let record = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              record is [String: Any] else {
            errorMessage = "所选文件不是有效的配对记录，请选择此 iPhone 生成的配对文件。"
            return false
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = docs.appendingPathComponent("aircard_pairing.plist")

        do {
            try data.write(to: aircardURL, options: .atomic)

            let display = originalName ?? sourceURL.lastPathComponent
            UserDefaults.standard.set(display, forKey: "aircard.selectedPairingFileName")

            refreshPairingFile()
            originalCardPreviews.removeAll()
            replacementRecords.removeAll()
            for card in cards { reloadReplacementRecord(for: card.id) }
            attemptedOriginalPreviews.removeAll()
            originalPreviewQueue.removeAll()
            pairingStatus = "已载入配对文件 ✅（\(display)）"
            log.append("已导入配对文件：\(display)（\(data.count) 字节）")
            return true
        } catch {
            errorMessage = "保存配对文件失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Pairing File

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path) &&
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (UserDefaults.standard.string(forKey: "aircard.selectedPairingFileName") ?? (path as NSString).lastPathComponent) : ""
    }


    var pairingFileSizeString: String {
        let path = PairingController.pairingFilePath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func startPairing() {
        guard !cardOperationRunning else { errorMessage = "请等待卡面操作完成后重新配对。"; return }
        pairingPhase = .pairing
        pairingPIN = nil
        pairingStatus = "正在启动本地服务…"
        errorMessage = nil

        let ctrl = PairingController.shared

        Task {
            do {
                let path = try await ctrl.startAndWait()
                await MainActor.run {
                    self.pairingPhase = .idle
                    UserDefaults.standard.removeObject(forKey: "aircard.selectedPairingFileName")
                    self.refreshPairingFile()
                    self.pairingStatus = "配对成功！✅"
                    self.log.append("配对完成：\(path)")
                }
            } catch is CancellationError {
                self.pairingPhase = .idle
                self.pairingStatus = "已取消。"
            } catch {
                self.pairingPhase = .idle
                self.pairingStatus = ""
                self.errorMessage = "配对失败：\(error.localizedDescription)"
            }
        }

        // Poll PairingController status every 0.2s while pairing
        Task {
            while pairingPhase == .pairing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    guard self.pairingPhase == .pairing else { return }
                    self.pairingStatus = ctrl.pairingStatus
                    self.pairingPIN   = ctrl.pairingPIN
                }
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingStatus = ""
    }

    func deletePairingFile() {
        guard !cardOperationRunning else { errorMessage = "请等待卡面操作完成后删除配对文件。"; return }
        if isScanningCards { stopCardScanning() }
        do {
            try PairingController.deleteStoredPairingCredentials()
            UserDefaults.standard.removeObject(forKey: "aircard.selectedPairingFileName")
            hasPairingFile = false
            pairingFileName = ""
            pairingStatus = ""
            originalCardPreviews.removeAll()
            replacementRecords.removeAll()
            originalPreviewQueue.removeAll()
            attemptedOriginalPreviews.removeAll()
            log.append("已删除当前配对凭据")
            } catch {
            refreshPairingFile()
            errorMessage = "删除配对文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Network

    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = LoopbackVPNManager.shared.isConnected || vpn
        wifiUp = wifi
        networkDetail = detail
    }

    private func syncTargetHostToRust() {
        let host = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        host.withCString { _ = al_set_target_host($0) }
    }

    // MARK: - Card management & Live Scanner

    @Published var isScanningCards: Bool = false
    @Published var scanStatusText: String = ""
    @Published private(set) var isStoppingCardScan = false
    private var receivedWalletActivity = false
    private var scanAddedCardIDs = Set<String>()
    private let scanKeepAlive = KeepAlive()
    private var scanTimeoutTask: Task<Void, Never>?

    func toggleCardScanning() {
        guard !isStoppingCardScan else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if isScanningCards {
                stopCardScanning()
            } else {
                startCardScanning()
            }
        }
    }

    private static let dummyCardHashes: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    func startCardScanning() {
        guard !cardOperationRunning else { return }
        guard !isScanningCards else { return }
        refreshNetworkStatus()
        attemptedOriginalPreviews.removeAll()
        guard hasPairingFile else {
            errorMessage = "扫描前需要配对文件，请先配对此 iPhone 或选择 .plist 文件。"
            return
        }

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isScanningCards = true
            isStoppingCardScan = false
            receivedWalletActivity = false
            scanAddedCardIDs.removeAll()
            scanStatusText = "正在连接设备日志…"
        }
        log.append("已启动实时卡片扫描…")
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.stopCardScanning()
        }
        scanKeepAlive.startAudio()

        syncTargetHostToRust()
        let pairingPath = PairingController.pairingFilePath()

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>? = nil

            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(
                    pairC,
                    { _, line in
                        guard let line = line else { return }
                        let lineStr = String(cString: line)
                        if lineStr.hasPrefix("[AirCard.Scan] ") {
                            let message = String(lineStr.dropFirst("[AirCard.Scan] ".count))
                            DispatchQueue.main.async {
                                guard let vm = AppViewModel.shared, vm.isScanningCards, !vm.isStoppingCardScan else { return }
                                vm.scanStatusText = message
                                vm.log.append(message)
                            }
                            return
                        }
                        let lower = lineStr.lowercased()
                        // Pre-filter on background thread to prevent flooding the main runloop
                        if lower.contains("pass") ||
                           lower.contains("card") ||
                           lower.contains("stockholm") ||
                           lower.contains("wallet") ||
                           lower.contains("nfcd") ||
                           lower.contains("nanopass") ||
                           lower.contains("verificationcheck") ||
                           lower.contains("dashboard") ||
                           lower.contains("setactivepaymentapplet") {
                            DispatchQueue.main.async {
                                AppViewModel.shared?.processSyslogLine(lineStr)
                            }
                        }
                    },
                    nil,
                    &outError
                )
            }

            let errStr = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }

            DispatchQueue.main.async {
                guard let vm = AppViewModel.shared else { return }
                vm.scanTimeoutTask?.cancel()
                vm.scanTimeoutTask = nil
                vm.scanKeepAlive.stopAll()
                vm.isScanningCards = false
                if rc != 0 && !vm.isStoppingCardScan {
                    let msg = errStr ?? "rc=\(rc)"
                    vm.scanStatusText = "扫描已停止：\(msg)"
                    vm.log.append("❌ 扫描出错：\(msg)")
                    vm.errorMessage = "卡片扫描出错：\(msg)"
                } else {
                    vm.scanStatusText = "扫描已停止，本次扫描新增 \(vm.scanAddedCardIDs.count) 张卡片"
                    vm.log.append(vm.scanStatusText)
                }
                vm.isStoppingCardScan = false
            }
        }
        thread.name = "AirCard.SyslogScanner"
        thread.stackSize = 4 * 1024 * 1024 // 4 MB stack
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopCardScanning() {
        guard isScanningCards, !isStoppingCardScan else { return }
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        isStoppingCardScan = true
        al_syslog_stream_stop()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            scanStatusText = "正在停止扫描…"
        }
        saveCards()
    }

    func processSyslogLine(_ line: String) {
        guard isScanningCards, !isStoppingCardScan else { return }
        let lower = line.lowercased()
        let isWalletSubsystem = lower.contains("passd") ||
                                lower.contains("nfcd") ||
                                lower.contains("passbook") ||
                                lower.contains("passkit") ||
                                lower.contains("stockholm") ||
                                lower.contains("nanopassd") ||
                                lower.contains("wallet") ||
                                lower.contains("pdcardfilemanager") ||
                                lower.contains("pdpasslibrary") ||
                                lower.contains("verificationcheck") ||
                                lower.contains("/cards/") || lower.contains("nfcd") || lower.contains("dashboard") || lower.contains("setactivepaymentapplet")

        guard isWalletSubsystem else { return }

        let isWalletContext = lower.contains("card") ||
                              lower.contains("pass") ||
                              lower.contains("payment") ||
                              lower.contains("pkpass") ||
                              lower.contains("uniqueid") ||
                              lower.contains("identifier") ||
                              lower.contains("face") ||
                              lower.contains("cache") ||
                              lower.contains("stockholm") ||
                              lower.contains("pdcardfilemanager") ||
                              lower.contains("pdpasslibrary") ||
                              lower.contains("verificationcheck") ||
                              lower.contains("/cards/") || lower.contains("nfcd") || lower.contains("dashboard") || lower.contains("setactivepaymentapplet")

        guard isWalletContext else { return }
        if !receivedWalletActivity {
            receivedWalletActivity = true
            log.append("已收到钱包活动日志，正在匹配卡片标识…")
            if cards.isEmpty { scanStatusText = "已收到钱包活动，正在等待卡片标识…" }
        }

        var candidates = WalletScanParser.cardIDs(in: line)
        if candidates.isEmpty && (lower.contains("passid") || lower.contains("cardid") || lower.contains("dashboard loading")) {
            candidates = WalletScanParser.fallbackCardIDs(in: line)
        }
        for raw in candidates {
            guard let id = CardItem.cleanCardId(raw), !Self.dummyCardHashes.contains(id) else { continue }
            if cards.contains(where: { $0.id == id }) {
                requestOriginalCardPreview(for: id)
                continue
            }
            cards.append(CardItem(id: id, name: savedCardName(for: id), isSelected: true))
            scanAddedCardIDs.insert(id)
            reloadReplacementRecord(for: id)
            saveCards()
            scanStatusText = "发现卡片：\(id)"
            log.append("发现卡片：\(id)")
            requestOriginalCardPreview(for: id)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    nonisolated static func cardImagePath(for cardId: String) -> URL {
        let safeId = cardId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cardsDir = docDir.appendingPathComponent("WalletCards", isDirectory: true)
        if !FileManager.default.fileExists(atPath: cardsDir.path) {
            try? FileManager.default.createDirectory(at: cardsDir, withIntermediateDirectories: true)
        }
        return cardsDir.appendingPathComponent("card_\(safeId).png")
    }

    func loadSavedCards() {
        let foundHashes = UserDefaults.standard.stringArray(forKey: cardsStorageKey) ?? []
        var unique: [String] = []
        for raw in foundHashes {
            if let clean = CardItem.cleanCardId(raw), !unique.contains(clean) {
                unique.append(clean)
            }
        }
        let names = UserDefaults.standard.dictionary(forKey: "aircard.cardNames") as? [String: String] ?? [:]
        cards = unique.filter { !Self.dummyCardHashes.contains($0) }.map { id in
            let path = Self.cardImagePath(for: id)
            let data = try? Data(contentsOf: path)
            // Keep enough pixels for the full-width card on Retina displays.
            let img = data.flatMap { ImageEngine.safeImageFromData($0, maxDimension: 1536) }
            return CardItem(id: id, name: names[id].flatMap { CardItem.cleanName($0) }, customImageData: data, customImage: img)
        }
        originalCardPreviews = [:]
        replacementRecords = [:]
        let pairingPath = PairingController.pairingFilePath()
        for card in cards {
            reloadReplacementRecord(for: card.id)
            if let image = Self.loadOriginalCardPreview(id: card.id, pairingPath: pairingPath) {
                originalCardPreviews[card.id] = image
            }
        }
    }

    private nonisolated static func loadOriginalCardPreview(id: String, pairingPath: String) -> UIImage? {
        let root = originalCardBackupURL(for: id)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery.json").path),
              let record = try? Data(contentsOf: root.appendingPathComponent("snapshot.json")),
              let snapshot = (try? JSONSerialization.jsonObject(with: record)) as? [String: Any],
              snapshot["version"] as? Int == 1, snapshot["card"] as? String == id,
              let pairing = try? Data(contentsOf: URL(fileURLWithPath: pairingPath)),
              snapshot["pairing"] as? String == SHA256.hash(data: pairing).map({ String(format: "%02x", $0) }).joined(),
              let files = snapshot["files"] as? [String: String] else { return nil }
        let names = ["cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png", "cardBackgroundCombined.pdf",
                     "background@3x.png", "background@2x.png", "background.pdf",
                     "diffuse@3x.png", "diffuse@2x.png", "strip@3x.png", "strip@2x.png", "strip.pdf"]
        for name in names {
            guard let hash = files[name],
                  let data = try? Data(contentsOf: root.appendingPathComponent("artwork").appendingPathComponent(name)),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { continue }
            if let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) { return image }
            if name.hasSuffix(".pdf"), let provider = CGDataProvider(data: data as CFData),
               let document = CGPDFDocument(provider), let page = document.page(at: 1) {
                let box = page.getBoxRect(.mediaBox)
                guard box.width > 0, box.height > 0 else { continue }
                let scale = min(1024 / box.width, 1024 / box.height)
                let size = CGSize(width: box.width * scale, height: box.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return UIGraphicsImageRenderer(size: size, format: format).image { context in
                    context.cgContext.translateBy(x: 0, y: size.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                    context.cgContext.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
                    context.cgContext.drawPDFPage(page)
                }
            }
        }
        return nil
    }

    private func requestOriginalCardPreview(for id: String) {
        guard originalCardPreviews[id] == nil, !attemptedOriginalPreviews.contains(id), hasPairingFile,
              let card = cards.first(where: { $0.id == id }), card.uiImage == nil else { return }
        attemptedOriginalPreviews.insert(id)
        originalPreviewQueue.append(id)
        processOriginalPreviewQueue()
    }

    private func processOriginalPreviewQueue() {
        guard !cardOperationRunning, !originalPreviewQueue.isEmpty else { return }
        let id = originalPreviewQueue.removeFirst()
        guard cards.contains(where: { $0.id == id }) else { processOriginalPreviewQueue(); return }
        loadingOriginalCardID = id
        syncTargetHostToRust()
        let pairingPath = PairingController.pairingFilePath()
        Task {
            defer {
                loadingOriginalCardID = nil
                cardKeepAlive.stopAll()
                processOriginalPreviewQueue()
            }
            cardKeepAlive.startAudio()
            log.append("正在获取原始卡面：\(id.prefix(12))…")
            // Backups return staged images before reporting success; never show an unreturned image.
            let error = await Self.performCardBackup(pairingPath: pairingPath, id: id, restoring: false, logToActivity: true)
            if let error {
                log.append("原始卡面预览未获取：\(error)")
                if FileManager.default.fileExists(atPath: Self.originalCardBackupURL(for: id).appendingPathComponent("recovery.json").path) {
                    originalPreviewQueue.removeAll()
                    stopCardScanning()
                    errorMessage = "原始图片归位未完成，请通过卡片菜单使用移除并恢复。恢复记录已保留。"
                }
                return
            }
            let image = await Task.detached(priority: .utility) {
                Self.loadOriginalCardPreview(id: id, pairingPath: pairingPath)
            }.value
            if let image, cards.contains(where: { $0.id == id }) {
                originalCardPreviews[id] = image
                log.append("原始卡面预览已载入：\(id.prefix(12))")
            } else {
                log.append("原始卡面已备份，但没有可显示的图片。")
            }
        }
    }

    var selectedCards: [CardItem] {
        cards.filter { $0.isSelected }
    }

    var canRestoreSelectedCards: Bool {
        !cardOperationRunning && !selectedCards.isEmpty &&
        selectedCards.allSatisfy { canRestoreOriginalCardFace(for: $0.id) }
    }

    func removeSelectedCards() {
        guard !cardOperationRunning else { return }
        let selected = selectedCards
        guard !selected.isEmpty else { return }
        if selected.contains(where: {
            FileManager.default.fileExists(atPath: Self.originalCardBackupURL(for: $0.id).appendingPathComponent("recovery.json").path)
        }) {
            errorMessage = "所选卡片存在中断恢复记录，请先使用移除并恢复，再移除记录。"
            return
        }
        for card in selected {
            guard deleteCard(id: card.id, clearOriginalBackup: false) else { return }
        }
    }

    func saveCards() {
        let hashes = cards.map(\.id)
        UserDefaults.standard.set(hashes, forKey: cardsStorageKey)
        // Plain removal keeps names; successful restore-and-remove clears the corresponding name.
        var names = UserDefaults.standard.dictionary(forKey: "aircard.cardNames") as? [String: String] ?? [:]
        for card in cards {
            if let name = card.name.flatMap({ CardItem.cleanName($0) }) {
                names[card.id] = name
            }
        }
        UserDefaults.standard.set(names, forKey: "aircard.cardNames")
    }

    private func savedCardName(for id: String) -> String? {
        let names = UserDefaults.standard.dictionary(forKey: "aircard.cardNames") as? [String: String] ?? [:]
        return names[id].flatMap { CardItem.cleanName($0) }
    }

    func renameCard(id: String, name: String) {
        guard !cardOperationRunning, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        guard let name = CardItem.cleanName(name) else {
            errorMessage = "卡片名称需为 1 到 5 个字符。"
            return
        }
        cards[index].name = name
        saveCards()
    }

    func setSkinForSelectedCards(image: UIImage) {
        for card in cards where card.isSelected {
            setCardImage(for: card.id, image: image)
        }
    }

    func selectAllCards(_ selected: Bool) {
        guard !cards.isEmpty else { return }
        cards = cards.map {
            var c = $0
            c.isSelected = selected
            return c
        }
    }

    func addCardHash(_ raw: String) {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var added = 0
        for p in parts {
            if let clean = CardItem.cleanCardId(p),
               !cards.contains(where: { $0.id == clean }) {
                cards.append(CardItem(id: clean, name: savedCardName(for: clean)))
                reloadReplacementRecord(for: clean)
                added += 1
            }
        }
        if added > 0 { saveCards() }
    }

    func setCardSelected(id: String, selected: Bool) {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            cards[idx].isSelected = selected
        }
    }

    @discardableResult
    func moveCard(id: String, toIndex target: Int) -> Bool {
        guard !cardOperationRunning, cards.indices.contains(target),
              let source = cards.firstIndex(where: { $0.id == id }), source != target else { return false }
        cards.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
        saveCards()
        return true
    }

    func removeCard(id: String) {
        guard !cardOperationRunning else { return }
        _ = deleteCard(id: id, clearOriginalBackup: false)
    }

    @discardableResult
    private func deleteCard(id: String, clearOriginalBackup: Bool) -> Bool {
        let backup = Self.originalCardBackupURL(for: id)
        // Never discard the record needed to return staged artwork.
        guard !FileManager.default.fileExists(atPath: backup.appendingPathComponent("recovery.json").path) else {
            errorMessage = "此卡片存在中断恢复记录，请先使用移除并恢复，暂不移除记录或备份。"
            return false
        }
        do {
            let image = Self.cardImagePath(for: id)
            if FileManager.default.fileExists(atPath: image.path) {
                try FileManager.default.removeItem(at: image)
            }
            if clearOriginalBackup && FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
        } catch {
            errorMessage = "本地文件清理失败，卡片记录已保留：\(error.localizedDescription)"
            return false
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            cards.removeAll { $0.id == id }
        }
        imageRequestIDs.removeValue(forKey: id)
        pendingCardImageIDs.remove(id)
        originalCardPreviews.removeValue(forKey: id)
        originalPreviewQueue.removeAll { $0 == id }
        if clearOriginalBackup {
            // A restored card starts a new backup lifecycle when rediscovered.
            replacementRecords.removeValue(forKey: id)
            attemptedOriginalPreviews.remove(id)
            var names = UserDefaults.standard.dictionary(forKey: "aircard.cardNames") as? [String: String] ?? [:]
            names.removeValue(forKey: id)
            UserDefaults.standard.set(names, forKey: "aircard.cardNames")
        }
        saveCards()
        return true
    }

    nonisolated static func originalCardBackupURL(for id: String) -> URL {
        let folder = id.utf8.map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OriginalCardFaces", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    func hasOriginalCardBackup(for id: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.originalCardBackupURL(for: id).appendingPathComponent("snapshot.json").path)
    }

    func requiresOriginalCardRecovery(for id: String) -> Bool {
        hasOriginalCardBackup(for: id) || FileManager.default.fileExists(atPath: Self.originalCardBackupURL(for: id).appendingPathComponent("recovery.json").path)
    }

    private func reloadReplacementRecord(for id: String) {
        let url = Self.originalCardBackupURL(for: id).appendingPathComponent("replacement.json")
        guard let pairing = try? Data(contentsOf: URL(fileURLWithPath: PairingController.pairingFilePath())),
              let record = try? CardReplacementRecord.load(from: url),
              record.matches(cardID: id, pairingFingerprint: SHA256.hash(data: pairing).map({ String(format: "%02x", $0) }).joined()) else {
            replacementRecords.removeValue(forKey: id)
            return
        }
        if replacementRecords[id] != record { replacementRecords[id] = record }
    }

    private nonisolated static func saveReplacementRecord(id: String, pairingPath: String, status: CardReplacementRecord.Status, appliedImageFingerprint: String? = nil) throws {
        let pairing = try Data(contentsOf: URL(fileURLWithPath: pairingPath))
        let fingerprint = SHA256.hash(data: pairing).map { String(format: "%02x", $0) }.joined()
        let url = originalCardBackupURL(for: id).appendingPathComponent("replacement.json")
        let previous = try? CardReplacementRecord.load(from: url)
        let wasReplaced = previous?.matches(cardID: id, pairingFingerprint: fingerprint) == true && previous?.hasReplacedCardFace == true
        let record = CardReplacementRecord(cardID: id, pairingFingerprint: fingerprint, status: status,
                                           successfulReplacement: wasReplaced || status == .replaced,
                                           appliedImageFingerprint: appliedImageFingerprint)
        try record.save(to: url)
    }

    func isCardFaceReplaced(for id: String) -> Bool {
        replacementRecords[id]?.hasReplacedCardFace == true
    }

    func canRestoreOriginalCardFace(for id: String) -> Bool {
        guard cards.contains(where: { $0.id == id }) else { return false }
        let recovery = Self.originalCardBackupURL(for: id).appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: recovery.path) { return true }
        return hasOriginalCardBackup(for: id) && (replacementRecords[id]?.status.needsRestoration ?? false)
    }

    private nonisolated static func performCardBackup(pairingPath: String, id: String, restoring: Bool, logToActivity: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>?
                let root = originalCardBackupURL(for: id).path
                let result = pairingPath.withCString { pairing in
                    id.withCString { card in
                        root.withCString { directory in
                            let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, message in
                                guard let message else { return }
                                let line = String(cString: message)
                                let activity = context != nil
                                DispatchQueue.main.async {
                                    if activity { AppViewModel.shared?.log.append("    " + line) }
                                    else { AppViewModel.shared?.cardFlashLog.append("    " + line) }
                                }
                            }
                            if restoring {
                                return al_card_artwork_restore(pairing, card, directory, callback, nil, &outError)
                            }
                            return al_card_artwork_backup(pairing, card, directory, callback, logToActivity ? UnsafeMutableRawPointer(bitPattern: 1) : nil, &outError)
                        }
                    }
                }
                let message = outError.flatMap { String(validatingUTF8: $0) }
                if let outError { al_string_free(outError) }
                continuation.resume(returning: result == 0 ? nil : (message ?? "原始卡面操作失败。"))
            }
        }
    }

    func restoreAndDeleteCard(id: String) {
        restoreAndDeleteCards(ids: [id])
    }

    func restoreAndDeleteSelectedCards() {
        restoreAndDeleteCards(ids: selectedCards.map(\.id))
    }

    private func restoreAndDeleteCards(ids: [String]) {
        guard !cardOperationRunning, let firstID = ids.first else { return }
        for id in ids {
            guard requiresOriginalCardRecovery(for: id) else {
                errorMessage = "所选卡片没有原始卡面备份，无法恢复。可选择仅移除卡片。"
                return
            }
            guard canRestoreOriginalCardFace(for: id) else {
                errorMessage = "所选卡片没有已替换或中断写入记录，无需恢复。可选择仅移除卡片。"
                return
            }
        }
        guard hasPairingFile else { errorMessage = "请先选择创建备份时的配对文件。"; return }
        stopCardScanning()
        restoringCardID = firstID
        syncTargetHostToRust()
        let pairingPath = PairingController.pairingFilePath()
        Task {
            while isScanningCards { try? await Task.sleep(nanoseconds: 200_000_000) }
            cardKeepAlive.startAudio()
            defer { restoringCardID = nil; cardKeepAlive.stopAll() }
            for (index, id) in ids.enumerated() {
                restoringCardID = id
                cardFlashLog.append("[\(index + 1)/\(ids.count)] 正在恢复原始卡面 \(id.prefix(12))…")
                let error = await Self.performCardBackup(pairingPath: pairingPath, id: id, restoring: true)
                if let error {
                    errorMessage = "恢复未完成，当前卡片和备份已保留：\(error)"
                    cardFlashLog.append("❌ \(error)")
                    return
                }
                do {
                    let recordURL = Self.originalCardBackupURL(for: id).appendingPathComponent("replacement.json")
                    if FileManager.default.fileExists(atPath: recordURL.path) {
                        try Self.saveReplacementRecord(id: id, pairingPath: pairingPath, status: .original)
                        reloadReplacementRecord(for: id)
                    }
                } catch {
                    errorMessage = "原始卡面已恢复，但状态保存失败，卡片记录已保留：\(error.localizedDescription)"
                    cardFlashLog.append("⚠️ 恢复状态保存失败，未移除卡片记录。")
                    return
                }
                guard deleteCard(id: id, clearOriginalBackup: true) else {
                    cardFlashLog.append("⚠️ 恢复处理完成，但本地清理失败，卡片记录已保留。")
                    return
                }
                cardFlashLog.append("✅ 原始卡面已恢复，已清除该卡片在 AirCard 中的本地数据。")
            }
            cardFlashLog.append("✅ 已恢复并移除 \(ids.count) 张卡片，请彻底关闭钱包后重新打开查看。")
        }
    }

    func clearCardImage(for cardId: String) {
        guard !cardOperationRunning, let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        imageRequestIDs.removeValue(forKey: cardId)
        pendingCardImageIDs.remove(cardId)
        let path = Self.cardImagePath(for: cardId)
        do {
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        } catch {
            let data = try? Data(contentsOf: path)
            cards[index].customImageData = data
            cards[index].customImage = data.flatMap { ImageEngine.safeImageFromData($0, maxDimension: 1536) }
            errorMessage = "清除已选图片失败：\(error.localizedDescription)"
            return
        }
        cards[index].customImage = nil
        cards[index].customImageData = nil
        // Selected images are drafts; clearing them never resets the device replacement record.
        if originalCardPreviews[cardId] == nil {
            originalCardPreviews[cardId] = Self.loadOriginalCardPreview(id: cardId, pairingPath: PairingController.pairingFilePath())
        }
    }

    func setCardImage(for cardId: String, image: UIImage) {
        guard !cardOperationRunning else { return }
        guard let idx = cards.firstIndex(where: { $0.id == cardId }) else { return }
        let thumb = ImageEngine.normalizeAndDownsample(image, maxDimension: 1536)
        cards[idx].customImage = thumb

        let actualId = cards[idx].id
        let requestID = UUID()
        imageRequestIDs[actualId] = requestID
        pendingCardImageIDs.insert(actualId)
        let path = Self.cardImagePath(for: actualId)
        // Encode off the main thread; commit only if this selection is still current.
        Task.detached(priority: .userInitiated) {
            let data = ImageEngine.prepareCardImage(from: image)
            await MainActor.run {
                guard let vm = AppViewModel.shared, vm.imageRequestIDs[actualId] == requestID,
                      let index = vm.cards.firstIndex(where: { $0.id == actualId }) else { return }
                defer { vm.pendingCardImageIDs.remove(actualId) }
                do {
                    guard let data else { throw CardFaceLibraryError.imageMissing }
                    try data.write(to: path, options: .atomic)
                    vm.cards[index].customImageData = data
                } catch {
                    let data = try? Data(contentsOf: path)
                    vm.cards[index].customImageData = data
                    vm.cards[index].customImage = data.flatMap { ImageEngine.safeImageFromData($0, maxDimension: 1536) }
                    vm.errorMessage = "保存已选图片失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Card Flash (via Airlift exploit)

    var canFlashCards: Bool {
        hasPairingFile &&
        !cardOperationRunning &&
        !cards.contains { $0.isSelected && pendingCardImageIDs.contains($0.id) } &&
        !cards.isEmpty
    }

    private nonisolated static func imageFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func flashCards() {
        guard canFlashCards else { return }
        for card in cards where card.isSelected { reloadReplacementRecord(for: card.id) }
        let selected = cards.filter { card in
            guard card.isSelected, card.customImage != nil || card.customImageData != nil else { return false }
            let recovery = Self.originalCardBackupURL(for: card.id).appendingPathComponent("recovery.json")
            if FileManager.default.fileExists(atPath: recovery.path) { return true }
            guard let data = card.customImageData ?? (try? Data(contentsOf: Self.cardImagePath(for: card.id))) else { return true }
            return replacementRecords[card.id]?.needsApplication(imageFingerprint: Self.imageFingerprint(data)) ?? true
        }
        guard !selected.isEmpty else {
            cardToast = AppToast(message: "暂无需要更新的卡面")
            return
        }

        cardFlashPhase    = .running
        cardFlashProgress = 0
        cardFlashLog.removeAll()
        errorMessage = nil
        stopCardScanning()

        refreshNetworkStatus()
        if !vpnUp {
            cardFlashLog.append("⚠️ 未检测到回环 VPN，正在尝试使用其他地址连接设备…")
        }

        syncTargetHostToRust()
        let pairingPath = PairingController.pairingFilePath()

        Task.detached { [weak self] in
            guard let self = self else { return }
            while await self.isScanningCards { try? await Task.sleep(nanoseconds: 200_000_000) }
            await MainActor.run { self.cardKeepAlive.startAudio() }
            let total = Double(selected.count)
            var successCount = 0
            for (i, card) in selected.enumerated() {
                let cleanId = CardItem.cleanCardId(card.id) ?? card.id
                let safeCardId = cleanId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")

                await MainActor.run {
                    self.cardFlashLog.append("[\(i+1)/\(selected.count)] 正在应用卡面 \(cleanId.prefix(12))…")
                    self.cardFlashProgress = Double(i) / total
                }

                // Load source image at full resolution on demand to save memory
                let sourceImg: UIImage? = {
                    if let d = card.customImageData, let img = UIImage(data: d) { return img }
                    let p = Self.cardImagePath(for: cleanId)
                    if let d = try? Data(contentsOf: p), let img = UIImage(data: d) { return img }
                    return card.customImage
                }()

                guard let sourceImg = sourceImg else {
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 卡片 \(cleanId.prefix(8)) 未设置图片") }
                    continue
                }

                // 1. Prepare multi-resolution skins
                var allSkins = ImageEngine.prepareAllCardSkins(from: sourceImg)
                guard !allSkins.isEmpty else {
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 生成卡面失败") }
                    continue
                }

                await MainActor.run { self.cardFlashLog.append("  正在检查原始卡面备份…") }
                if let error = await Self.performCardBackup(pairingPath: pairingPath, id: cleanId, restoring: false) {
                    await MainActor.run { self.cardFlashLog.append("  ❌ 备份失败，未替换卡面：\(error)") }
                    continue
                }
                let receiptURL = Self.originalCardBackupURL(for: cleanId).appendingPathComponent("snapshot.json")
                let receiptData = try? Data(contentsOf: receiptURL)
                let receipt = receiptData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let names = Set((receipt?["files"] as? [String: String])?.keys.map { $0 } ?? [])
                allSkins = allSkins.filter { names.contains($0.key) }
                guard !allSkins.isEmpty else {
                    await MainActor.run { self.cardFlashLog.append("  ❌ 没有匹配的原始卡面文件，未进行替换。") }
                    continue
                }

                let stageCardDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("airlift_card_\(safeCardId)_\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: stageCardDir, withIntermediateDirectories: true)
                    for (name, data) in allSkins {
                        try data.write(to: stageCardDir.appendingPathComponent(name), options: .atomic)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: stageCardDir)
                    await MainActor.run { self.cardFlashLog.append("  ❌ 准备卡面文件失败，未替换卡面：\(error.localizedDescription)") }
                    continue
                }

                let pkpassTarget = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"

                await MainActor.run {
                    self.cardFlashLog.append("  ⚡ 正在向 \(cleanId.prefix(10)).pkpass 写入卡面…")
                }

                do {
                    try Self.saveReplacementRecord(id: cleanId, pairingPath: pairingPath, status: .writing)
                    await MainActor.run { self.reloadReplacementRecord(for: cleanId) }
                } catch {
                    try? FileManager.default.removeItem(at: stageCardDir)
                    await MainActor.run { self.cardFlashLog.append("  ❌ 无法保存写入状态，未替换卡面：\(error.localizedDescription)") }
                    continue
                }

                var writeOk = false
                var errDesc: String? = nil
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageCardDir.path.withCString { srcC in
                                pkpassTarget.withCString { tgtC in
                                    al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async { AppViewModel.shared?.cardFlashLog.append("    " + line) }
                                    }, nil, &outError)
                                }
                            }
                        }
                        if let p = outError {
                            errDesc = String(validatingUTF8: p)
                            al_string_free(p)
                        }
                        writeOk = (rc == 0)
                        cont.resume()
                    }
                }

                try? FileManager.default.removeItem(at: stageCardDir)

                if !writeOk {
                    await MainActor.run {
                        self.cardFlashLog.append("  ❌ 写入卡面失败： \(errDesc ?? "文件操作失败")")
                        self.cardFlashLog.append("  写入未确认完成，已保留恢复入口，可使用‘移除并恢复卡片’恢复原始卡面。")
                    }
                    continue
                }

                do {
                    try Self.saveReplacementRecord(id: cleanId, pairingPath: pairingPath, status: .replaced)
                    await MainActor.run { self.reloadReplacementRecord(for: cleanId) }
                } catch {
                    // The durable writing record still permits restoring after a successful device write.
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 卡面已写入，但替换状态更新失败，已保留恢复入口：\(error.localizedDescription)") }
                }

                await MainActor.run {
                    self.cardFlashLog.append("  卡面已写入，正在清除卡片缓存…")
                }

                // 2. Only report success after both cache writes complete.
                let stageInvDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("airlift_inv_\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: stageInvDir, withIntermediateDirectories: true)
                    for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
                        try Data("corrupted".utf8).write(to: stageInvDir.appendingPathComponent(leaf), options: .atomic)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: stageInvDir)
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 卡面已写入，但准备缓存刷新失败，已保留恢复入口：\(error.localizedDescription)") }
                    continue
                }

                var cacheErrors: [String] = []
                for ext in [".cache", ".pkcache"] {
                    let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cleanId)\(ext)"
                    let cacheError: String? = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            var outError: UnsafeMutablePointer<CChar>? = nil
                            let rc = pairingPath.withCString { pairC in
                                stageInvDir.path.withCString { srcC in
                                    cacheTarget.withCString { tgtC in
                                        al_exploit_write_dir(pairC, srcC, tgtC, nil, nil, &outError)
                                    }
                                }
                            }
                            let message = outError.flatMap { String(validatingUTF8: $0) }
                            if let p = outError { al_string_free(p) }
                            cont.resume(returning: rc == 0 ? nil : (message ?? "缓存文件操作失败。"))
                        }
                    }
                    if let cacheError { cacheErrors.append("\(ext): \(cacheError)") }
                }
                try? FileManager.default.removeItem(at: stageInvDir)
                if !cacheErrors.isEmpty {
                    let detail = cacheErrors.joined(separator: "；")
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 卡面已写入，但缓存刷新未完成，已保留恢复入口：\(detail)") }
                    continue
                }

                // Deduplicate only fully completed applications; failed cache writes remain retryable.
                do {
                    let data = try card.customImageData ?? Data(contentsOf: Self.cardImagePath(for: cleanId))
                    try Self.saveReplacementRecord(id: cleanId, pairingPath: pairingPath, status: .replaced,
                                                   appliedImageFingerprint: Self.imageFingerprint(data))
                    await MainActor.run { self.reloadReplacementRecord(for: cleanId) }
                } catch {
                    await MainActor.run { self.cardFlashLog.append("  ⚠️ 卡面与缓存已更新，但应用记录保存失败，请重试：\(error.localizedDescription)") }
                    continue
                }

                successCount += 1
                await MainActor.run {
                    self.cardFlashLog.append("  ✅ 已清除卡片缓存")
                    self.cardFlashProgress = Double(i + 1) / total
                }
            }

            await MainActor.run {
                self.cardKeepAlive.stopAll()
                if successCount > 0 {
                    self.cardFlashPhase = .done(ok: true)
                    self.cardFlashProgress = 1.0
                    self.cardFlashLog.append("🎉 已应用 \(successCount)/\(selected.count) 张卡片！请彻底关闭“钱包”应用后重新打开以查看效果。")
                    self.successAlertMessage = "已成功为 \(successCount) 张卡片应用卡面！\n\n请彻底关闭 iPhone 上的“钱包”应用后重新打开，或重启手机以查看新卡面。"
                    self.showSuccessAlert = true
                } else {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append("❌ 没有卡片完整完成应用，请查看上述错误。已写入卡面的卡片保留恢复入口。")
                }
            }
        }
    }

    func appendLog(_ line: String) {
        let formatted = line.components(separatedBy: "\n").map { entry -> String in
            guard let separator = entry.firstIndex(where: { $0.isWhitespace }) else { return entry }
            let timestamp = String(entry[..<separator])
            guard let date = logTimestampParser.date(from: timestamp)
                ?? logTimestampParserWithoutFraction.date(from: timestamp) else { return entry }
            return logTimestampDisplay.string(from: date) + String(entry[separator...])
        }.joined(separator: "\n")
        log.append(formatted)
    }

    func reset() {
        cardFlashPhase = .idle
        cardFlashProgress = 0
        errorMessage = nil
    }
}
