import Foundation
import SwiftUI

enum AppTranslation {
    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    struct Rule {
        let source: String
        let target: String
        let pattern: NSRegularExpression
        let indices: [String]
    }

    static func rules(for values: [String: String]) -> [Rule] {
        let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        return values.keys.sorted { $0.count > $1.count }.compactMap { key in
            let matches = placeholder.matches(in: key, range: NSRange(key.startIndex..., in: key))
            guard !matches.isEmpty else { return nil }
            var pattern = "^", position = key.startIndex
            var indices: [String] = []
            for match in matches {
                guard let range = Range(match.range, in: key), let indexRange = Range(match.range(at: 1), in: key) else { return nil }
                pattern += NSRegularExpression.escapedPattern(for: String(key[position..<range.lowerBound])) + "([\\s\\S]*?)"
                indices.append(String(key[indexRange]))
                position = range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(key[position...])) + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(source: key, target: values[key]!, pattern: regex, indices: indices)
        }
    }

    static let templates = rules(for: english)

    static func translate(_ value: String, values: [String: String] = english,
                          rules: [Rule] = templates, depth: Int = 0) -> String {
        if let result = values[value] { return result }
        guard depth < 4 else { return value }
        for rule in rules {
            guard let match = rule.pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            // Preserve user-authored names and file names inside application messages.
            let preservesNames = ["使用{0}", "编辑{0}", "确认移除{0}", "准备移除{0}",
                                  "已导入配对文件：{0}（{1} 字节）", "已载入配对文件 ✅（{0}）", "已配对：{0}（{1} 字节）"].contains(rule.source)
            let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
            var result = rule.target
            // Substitute from the end, so inserted text can never become another placeholder.
            for token in placeholder.matches(in: rule.target, range: NSRange(rule.target.startIndex..., in: rule.target)).reversed() {
                guard let indexRange = Range(token.range(at: 1), in: rule.target),
                      let capture = rule.indices.firstIndex(of: String(rule.target[indexRange])),
                      let valueRange = Range(match.range(at: capture + 1), in: value),
                      let outputRange = Range(token.range, in: result) else { continue }
                let argument = String(value[valueRange])
                result.replaceSubrange(outputRange, with: preservesNames ? argument : translate(argument, values: values, rules: rules, depth: depth + 1))
            }
            return result
        }
        return value
    }
}

func AppL(_ value: String) -> String {
    guard AppLanguage.shared.code == "en" else { return value }
    guard value.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return value }
    return AppTranslation.translate(value)
}

struct AppLanguageMenu: View {
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        Menu {
            Button { language.select("zh-Hans") } label: {
                Label("简体中文", systemImage: language.code == "zh-Hans" ? "checkmark" : "globe")
            }
            Button { language.select("en") } label: {
                Label("English", systemImage: language.code == "en" ? "checkmark" : "globe")
            }
        } label: {
            HStack(spacing: 4) {
                Text(language.code == "en" ? "EN" : "ZH")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1), in: Capsule())
        }
        .accessibilityLabel(language.code == "en" ? "Language" : "语言")
        .accessibilityValue(language.code == "en" ? "English" : "简体中文")
    }
}

final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    @Published private(set) var code: String

    private init() {
        code = Self.initialCode(savedCode: UserDefaults.standard.string(forKey: "aircard.language"),
                                preferredLanguages: Locale.preferredLanguages)
    }

    static func initialCode(savedCode: String?, preferredLanguages: [String]) -> String {
        if let savedCode, savedCode == "en" || savedCode == "zh-Hans" { return savedCode }
        let systemLanguage = preferredLanguages.first?
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased()
        return systemLanguage == "zh" ? "zh-Hans" : "en"
    }

    func select(_ code: String) {
        let value = code == "en" ? "en" : "zh-Hans"
        UserDefaults.standard.set(value, forKey: "aircard.language")
        self.code = value
    }
}
