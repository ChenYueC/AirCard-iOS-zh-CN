import Foundation

/// Device writes are tracked independently from selected images and original backups.
struct CardReplacementRecord: Codable, Equatable {
    enum Status: String, Codable {
        case writing
        case replaced
        case original

        var needsRestoration: Bool { self != .original }
    }

    let version: Int
    let cardID: String
    let pairingFingerprint: String
    let status: Status

    init(cardID: String, pairingFingerprint: String, status: Status) {
        version = 1
        self.cardID = cardID
        self.pairingFingerprint = pairingFingerprint
        self.status = status
    }

    func matches(cardID: String, pairingFingerprint: String) -> Bool {
        version == 1 && self.cardID == cardID && self.pairingFingerprint == pairingFingerprint
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> CardReplacementRecord {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
