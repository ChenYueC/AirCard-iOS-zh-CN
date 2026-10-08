// Based on LocalDevVPN / StosVPN. See LocalDevVPN-NOTICE.txt.
import NetworkExtension
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let packetQueue = DispatchQueue(label: "com.wallet.aircard.loopback")
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            guard error == nil else { completionHandler(error); return }
            self.packetQueue.async {
                self.running = true
                self.readPackets()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetQueue.async {
            self.running = false
            completionHandler()
        }
    }

    private func readPackets() {
        guard running else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.packetQueue.async {
                guard self.running else { return }
                var reflected: [Data] = []
                for (packet, proto) in zip(packets, protocols) where proto.int32Value == AF_INET {
                    if let response = LoopbackPacket.reflect(packet) { reflected.append(response) }
                }
                if !reflected.isEmpty {
                    self.packetFlow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count))
                }
                self.readPackets()
            }
        }
    }
}
