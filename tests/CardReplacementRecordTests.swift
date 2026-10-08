import XCTest
@testable import AirCard_iOS

final class CardReplacementRecordTests: XCTestCase {
    private let id = "abcdefghijklmnopqrstuvwxyza="
    private let pairing = String(repeating: "a", count: 64)

    func testWriteAndRestoreStateSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("replacement.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for status in [CardReplacementRecord.Status.writing, .replaced, .original] {
            let record = CardReplacementRecord(cardID: id, pairingFingerprint: pairing, status: status)
            try record.save(to: url)
            let loaded = try CardReplacementRecord.load(from: url)
            XCTAssertEqual(loaded, record)
            XCTAssertEqual(loaded.status.needsRestoration, status != .original)
        }
    }

    func testRecordMustMatchCardDeviceAndVersion() throws {
        let record = CardReplacementRecord(cardID: id, pairingFingerprint: pairing, status: .replaced)
        XCTAssertTrue(record.matches(cardID: id, pairingFingerprint: pairing))
        XCTAssertFalse(record.matches(cardID: "another-card", pairingFingerprint: pairing))
        XCTAssertFalse(record.matches(cardID: id, pairingFingerprint: "another-device"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["version"] = 2
        let newer = try JSONDecoder().decode(CardReplacementRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(newer.matches(cardID: id, pairingFingerprint: pairing))
    }

    func testMalformedRecordIsRejected() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(CardReplacementRecord.self, from: Data("invalid".utf8)))
        let invalid = Data(#"{"version":1,"cardID":"card","pairingFingerprint":"device","status":"unknown"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CardReplacementRecord.self, from: invalid))
    }
}
