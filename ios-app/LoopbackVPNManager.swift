import Foundation
import NetworkExtension
import Combine

@MainActor
final class LoopbackVPNManager: ObservableObject {
    static let shared = LoopbackVPNManager()
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isBusy = true
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?

    var isConnected: Bool { status == .connected }
    var isTransitioning: Bool {
        isBusy || status == .connecting || status == .disconnecting || status == .reasserting
    }
    var label: String {
        switch status {
        case .connected: return "回环 VPN 已开启"
        case .connecting, .reasserting: return "正在连接"
        case .disconnecting: return "正在断开"
        default: return isBusy ? "正在准备" : "回环 VPN"
        }
    }

    // Read the embedded extension's actual identifier so re-signing can change bundle IDs.
    private var providerBundleIdentifier: String? {
        guard let directory = Bundle.main.builtInPlugInsURL,
              let extensions = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return extensions.compactMap { Bundle(url: $0) }.first {
            let info = $0.infoDictionary?["NSExtension"] as? [String: Any]
            return info?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
        }?.bundleIdentifier
    }

    private init() {
        statusObserver = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
        Task { await reload() }
    }

    func reload() async {
        guard manager == nil, let identifier = providerBundleIdentifier else {
            isBusy = false
            updateStatus()
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
            }
            updateStatus()
        } catch {
            errorMessage = "读取回环 VPN 配置失败：\(error.localizedDescription)"
        }
    }

    func toggle() async {
        guard !isTransitioning else { return }
        if isConnected {
            manager?.connection.stopVPNTunnel()
            updateStatus()
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let identifier = providerBundleIdentifier else {
                throw NSError(domain: "AirCardVPN", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "未找到内置 VPN 扩展，请确认签名时保留了扩展。"])
            }
            let configuration = manager ?? NETunnelProviderManager()
            let tunnel = NETunnelProviderProtocol()
            tunnel.providerBundleIdentifier = identifier
            tunnel.serverAddress = "10.7.0.1"
            tunnel.disconnectOnSleep = false
            configuration.protocolConfiguration = tunnel
            configuration.localizedDescription = "AirCard VPN"
            configuration.isEnabled = true
            try await configuration.saveToPreferences()
            try await configuration.loadFromPreferences()
            manager = configuration
            try configuration.connection.startVPNTunnel()
            updateStatus()
        } catch {
            updateStatus()
            errorMessage = "启动回环 VPN 失败：\(error.localizedDescription)\n请确认主应用和 VPN 扩展均已正确签名，且描述文件包含网络扩展权限。"
        }
    }

    private func updateStatus() {
        let previous = status
        status = manager?.connection.status ?? .invalid
        AppViewModel.shared?.refreshNetworkStatus()
        if status == .disconnected && (previous == .connecting || previous == .connected || previous == .reasserting) {
            manager?.connection.fetchLastDisconnectError { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.errorMessage = "回环 VPN 已断开：\(error.localizedDescription)"
                }
            }
        }
    }
}
