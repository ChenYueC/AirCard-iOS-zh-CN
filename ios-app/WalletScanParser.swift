import Foundation

public enum WalletScanParser {
    static let cardReferences: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #""passId"\s*:\s*"([-A-Za-z0-9_+=]{20,64})""#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"(?:activating payment pass ID|pass ID)\s*:\s*([-A-Za-z0-9_+=]{20,64})(?=[\s"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s\"'\),]|$)"#),
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,80})(?=[,\s\"'\)]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,80})\s+-"#, options: .caseInsensitive),
    ]

    static let inSessionList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*[:=]\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )

    static let cardID = try! NSRegularExpression(pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#)

    static let fallbackToken = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9+/=])([A-Za-z0-9+/_-]{27}=)(?![-A-Za-z0-9+/=])"#
    )

    static let placeholders: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    public static func cardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        var result: [String] = []

        func add(_ id: String) {
            guard !placeholders.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        for pattern in cardReferences {
            for match in pattern.matches(in: line, range: lineRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                add(String(line[range]))
            }
        }

        for match in inSessionList.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let sessionString = String(line[range])
            let sessionRange = NSRange(sessionString.startIndex..., in: sessionString)
            for cardMatch in cardID.matches(in: sessionString, range: sessionRange) {
                guard let cardRange = Range(cardMatch.range, in: sessionString) else { continue }
                add(String(sessionString[cardRange]))
            }
        }

        return result
    }

    public static func fallbackCardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        return fallbackToken.matches(in: line, range: lineRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            let id = String(line[range])
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

}
