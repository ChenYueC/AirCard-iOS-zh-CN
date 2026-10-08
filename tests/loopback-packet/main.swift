import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
var packet = [UInt8](repeating: 0, count: 40)
packet[0] = 0x45
packet[3] = 40
packet[8] = 64
packet[9] = 6
packet.replaceSubrange(12..<20, with: [10,7,0,2,10,7,0,1])
packet.replaceSubrange(20..<24, with: [0xc0,0x01,0xf2,0x7e])
let original = Data(packet)
let reflected = LoopbackPacket.reflect(original)!
expect(Array(reflected[12..<20]) == [10,7,0,1,10,7,0,2], "IPv4 addresses must be swapped")
expect(reflected.prefix(12) == original.prefix(12), "Header fields must remain unchanged")
expect(reflected.suffix(20) == original.suffix(20), "TCP ports and payload must remain unchanged")
expect(LoopbackPacket.reflect(reflected) == nil, "Responses must not be reflected again")
expect(LoopbackPacket.reflect(Data(packet.prefix(19))) == nil, "Truncated packets must be dropped")
packet[0] = 0x65
expect(LoopbackPacket.reflect(Data(packet)) == nil, "IPv6 packets must be dropped")
packet[0] = 0x44
expect(LoopbackPacket.reflect(Data(packet)) == nil, "Invalid IPv4 header lengths must be dropped")
packet[0] = 0x45; packet[3] = 60
expect(LoopbackPacket.reflect(Data(packet)) == nil, "Invalid total lengths must be dropped")
packet[3] = 40; packet[19] = 3
expect(LoopbackPacket.reflect(Data(packet)) == nil, "Unrelated destinations must be dropped")
print("PASS: loopback address reflection, payload preservation, invalid-packet rejection and loop prevention")
