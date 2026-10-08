// Based on the IPv4 reflection approach used by LocalDevVPN / StosVPN.
// See LocalDevVPN-NOTICE.txt for attribution and license.
import Foundation

enum LoopbackPacket {
    static func reflect(_ packet: Data) -> Data? {
        var bytes = [UInt8](packet)
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0f) * 4
        let totalLength = Int(bytes[2]) * 256 + Int(bytes[3])
        guard headerLength >= 20, totalLength >= headerLength, bytes.count >= totalLength else { return nil }
        // Only reflect the dedicated local tunnel: 10.7.0.2 -> 10.7.0.1.
        guard Array(bytes[12..<16]) == [10, 7, 0, 2],
              Array(bytes[16..<20]) == [10, 7, 0, 1] else { return nil }
        for index in 0..<4 { bytes.swapAt(12 + index, 16 + index) }
        // Address swapping preserves the IPv4 and TCP/UDP checksum sums.
        return Data(bytes)
    }
}
