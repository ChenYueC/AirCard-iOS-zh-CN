import XCTest
@testable import AirCard_iOS

@MainActor
final class AppLocalizationTests: XCTestCase {
    func testInitialLanguageFollowsPrimarySystemLanguage() {
        for code in ["zh", "zh-Hans-CN", "zh-Hant-TW", "zh-HK", "zh_Hant"] {
            XCTAssertEqual(AppLanguage.initialCode(savedCode: nil, preferredLanguages: [code]), "zh-Hans")
        }
        for languages in [["en-US", "zh-Hans"], ["ja-JP"], ["fr-FR"], []] {
            XCTAssertEqual(AppLanguage.initialCode(savedCode: nil, preferredLanguages: languages), "en")
        }
    }

    func testSavedLanguageOverridesSystemLanguage() {
        XCTAssertEqual(AppLanguage.initialCode(savedCode: "en", preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.initialCode(savedCode: "zh-Hans", preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.initialCode(savedCode: "invalid", preferredLanguages: ["zh-Hant"]), "zh-Hans")
    }

    func testLanguagePreferenceAndDynamicMessages() {
        let language = AppLanguage.shared
        let previous = language.code
        defer { language.select(previous) }
        language.select("en")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "aircard.language"), "en")
        XCTAssertEqual(AppL("配对"), "Pairing")
        XCTAssertEqual(AppL("扫描已停止，本次扫描新增 12 张卡片"), "Scan stopped. 12 new cards added this scan")
        XCTAssertEqual(AppL("字体不存在！"), "Font Missing!")
        XCTAssertEqual(AppL("设备地址：10.7.0.1 · 已检测到外部回环 VPN"), "Device address: 10.7.0.1 · External loopback VPN detected")
        language.select("zh-Hans")
        XCTAssertEqual(AppL("配对"), "配对")
    }

    func testNamesAndUnknownLogsArePreserved() {
        let values = AppTranslation.english
        let rules = AppTranslation.templates
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(AppTranslation.translate("使用删除", values: values, rules: rules), "Use 删除")
        XCTAssertEqual(AppTranslation.translate("已导入配对文件：配对（42 字节）", values: values, rules: rules), "Pairing file imported: 配对 (42 bytes)")
        XCTAssertEqual(AppTranslation.translate("unknown device log: M6nDwZrkYbFl"), "unknown device log: M6nDwZrkYbFl")
        XCTAssertEqual(AppTranslation.translate("活动日志（20 行）"), "Activity Log (20 lines)")
        XCTAssertEqual(AppTranslation.translate("失败：字体文件不能为空或超过 20 MB。"), "Failed: Font files must be nonempty and no larger than 20 MB.")
    }

    func testPlaceholderSubstitutionDoesNotRewriteInsertedValues() {
        let values = ["甲{0}乙{1}": "{1} / {0}"]
        XCTAssertEqual(AppTranslation.translate("甲{1}乙😀", values: values, rules: AppTranslation.rules(for: values)), "😀 / {1}")
    }

    func testArtworkFailureMessagesKeepPrefixesAndTranslateDetails() {
        XCTAssertEqual(AppTranslation.translate("暂无需要更新的卡面"), "No card faces need updating.")
        XCTAssertEqual(AppTranslation.translate("  卡面已写入，正在清除卡片缓存…"), "  Artwork written. Clearing card caches…")
        XCTAssertEqual(
            AppTranslation.translate("  ⚠️ 卡面已写入，但缓存刷新未完成，已保留恢复入口：.cache: 缓存文件操作失败。"),
            "  ⚠️ Artwork was written, but the cache refresh did not complete. Restoration remains available: .cache: The cache file operation failed.")
        XCTAssertEqual(AppTranslation.translate("保存 Books 状态失败：connection lost"), "Saving the Books sync state failed: connection lost")
    }
}
