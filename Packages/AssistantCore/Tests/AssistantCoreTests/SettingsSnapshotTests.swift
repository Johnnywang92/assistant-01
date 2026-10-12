import XCTest
@testable import AssistantCore

/// 偏好设置快照的编解码与类型保真测试。
/// 核心风险：UserDefaults 里 Bool/Double/Int 底层都是 NSNumber，
/// 若快照不记录类型，`true` 会被还原成 `1.0`、`8.0` 会被还原成 `8`。
final class SettingsSnapshotTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - 编解码保真

    func testRoundTripPreservesEveryValueType() throws {
        let snapshot = SettingsSnapshotDTO(
            entries: [
                "assistant_custom_name": .string("小智"),
                "voice_reply_enabled": .bool(true),
                "user_off_work_minutes": .int(1080),
                "app_background_blur": .double(12.5),
                "custom_home_tabs_order_v1": .data(Data([0x01, 0x02, 0xFF]))
            ],
            wallpaperImageData: Data([0xAA, 0xBB])
        )

        let decoded = try decoder.decode(
            SettingsSnapshotDTO.self,
            from: try encoder.encode(snapshot)
        )

        XCTAssertEqual(decoded.entries["assistant_custom_name"], .string("小智"))
        XCTAssertEqual(decoded.entries["voice_reply_enabled"], .bool(true))
        XCTAssertEqual(decoded.entries["user_off_work_minutes"], .int(1080))
        XCTAssertEqual(decoded.entries["app_background_blur"], .double(12.5))
        XCTAssertEqual(decoded.entries["custom_home_tabs_order_v1"], .data(Data([0x01, 0x02, 0xFF])))
        XCTAssertEqual(decoded.wallpaperImageData, Data([0xAA, 0xBB]))
        XCTAssertEqual(decoded.itemCount, 6)
    }

    /// 最容易踩的坑：true 与 1.0、8.0 与 8 在 NSNumber 层是同一个东西，
    /// 快照必须让它们在还原后仍是不同的类型。
    func testBoolAndDoubleStayDistinct() throws {
        let snapshot = SettingsSnapshotDTO(
            entries: [
                "flag_on": .bool(true),
                "flag_off": .bool(false),
                "ratio": .double(1.0),
                "blur": .double(8.0),
                "count": .int(1)
            ]
        )

        let decoded = try decoder.decode(
            SettingsSnapshotDTO.self,
            from: try encoder.encode(snapshot)
        )

        XCTAssertEqual(decoded.entries["flag_on"], .bool(true))
        XCTAssertEqual(decoded.entries["flag_off"], .bool(false))
        XCTAssertEqual(decoded.entries["ratio"], .double(1.0))
        XCTAssertEqual(decoded.entries["blur"], .double(8.0))
        XCTAssertEqual(decoded.entries["count"], .int(1))

        // 反向确认：枚举值不相等即类型不同（SettingsValue 的 == 同时比较 case 与关联值）
        XCTAssertNotEqual(decoded.entries["flag_on"], .double(1.0))
        XCTAssertNotEqual(decoded.entries["blur"], .int(8))
    }

    /// 小数必须完整保留：模糊度 12.5 若被取整成 12，用户能直接看出背景不对。
    func testFractionalDoubleSurvives() throws {
        let snapshot = SettingsSnapshotDTO(entries: [
            "app_background_dim": .double(0.25),
            "periodic_report_daily_time_interval": .double(77400) // 21:30
        ])
        let decoded = try decoder.decode(
            SettingsSnapshotDTO.self,
            from: try encoder.encode(snapshot)
        )
        XCTAssertEqual(decoded.entries["app_background_dim"], .double(0.25))
        XCTAssertEqual(decoded.entries["periodic_report_daily_time_interval"], .double(77400))
    }

    // MARK: - 旧形状兼容

    func testDecodesWithoutWallpaperKey() throws {
        // 用真实编码器产出快照 JSON，再删掉 wallpaperImageData 键，
        // 模拟更早的快照形状（不手写枚举内部格式——那是合成 Codable 的实现细节）
        let snapshot = SettingsSnapshotDTO(entries: ["voice_reply_enabled": .bool(true)])
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(snapshot)
        ) as? [String: Any]
        object?.removeValue(forKey: "wallpaperImageData")
        let stripped = try JSONSerialization.data(withJSONObject: object ?? [:])

        let decoded = try decoder.decode(SettingsSnapshotDTO.self, from: stripped)
        XCTAssertEqual(decoded.entries["voice_reply_enabled"], .bool(true))
        XCTAssertNil(decoded.wallpaperImageData)
        XCTAssertEqual(decoded.itemCount, 1)
    }

    func testEmptyEntriesDecode() throws {
        let json = #"{"entries":{}}"#
        let decoded = try decoder.decode(SettingsSnapshotDTO.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.entries.isEmpty)
        XCTAssertEqual(decoded.itemCount, 0)
    }

    // MARK: - 写入 UserDefaults 的类型保真

    func testApplyWritesExactTypesToUserDefaults() throws {
        let suite = "SettingsSnapshotTests.suite"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let snapshot = SettingsSnapshotDTO(entries: [
            "voice_reply_enabled": .bool(true),
            "app_background_blur": .double(12.5),
            "user_off_work_minutes": .int(1080),
            "assistant_custom_name": .string("小智")
        ])
        snapshot.apply(to: defaults)

        XCTAssertEqual(defaults.object(forKey: "voice_reply_enabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "app_background_blur") as? Double, 12.5)
        XCTAssertEqual(defaults.object(forKey: "user_off_work_minutes") as? Int, 1080)
        XCTAssertEqual(defaults.string(forKey: "assistant_custom_name"), "小智")

        // 注意：NSNumber 层面 true 与 1、8.0 与 8 本就无法区分（`true as? Int` 会桥接成 1），
        // 所以「不串类型」的保证只能来自快照里的类型标签——由上面的往返测试覆盖。
        // 这里能断言的是：非整数 double 不会被取整（12.5 as? Int 为 nil）。
        XCTAssertNil(defaults.object(forKey: "app_background_blur") as? Int)
    }

    // MARK: - 白名单纪律

    func testWhitelistHasNoDuplicates() {
        let all = AssistantSettingsKeys.allKeys
        XCTAssertEqual(all.count, Set(all).count, "白名单存在重复键：\(all)")
    }

    func testWhitelistContainsLanguageKey() {
        XCTAssertTrue(AssistantSettingsKeys.stringKeys.contains(AssistantSettingsKeys.languagePreference))
        XCTAssertEqual(AssistantSettingsKeys.languagePreference, "app_language_preference")
    }

    func testWhitelistKeysAreNonEmptyAndPrefixed() {
        for key in AssistantSettingsKeys.allKeys {
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(key.hasPrefix(" "), "键名不应含空格: \(key)")
        }
    }

    /// 纪律测试：安全材料与设备缓存绝不能进白名单。
    /// 新增偏好时若把这类键登记进来，这条测试会失败。
    func testWhitelistExcludesSecurityAndCacheKeys() {
        let forbidden: Set<String> = [
            "app_lock_passcode_hash",          // 应用锁 PIN 哈希
            "app_lock_enabled",                // 设备级安全开关（应在设备上重新设置）
            "llm_remote_context_consent",      // 隐私同意不能替用户迁移
            "llm_developer_endpoint",          // 局域网地址
            "llm_validated_digest",            // 模型校验缓存
            "weather_cached_temp",             // 天气缓存
            "cached_user_current_city",        // 城市缓存
            "clipboard_last_handled_change_count", // 剪贴板设备状态
            "has_completed_permission_onboarding_v1" // 权限引导状态
        ]
        let intersection = forbidden.intersection(AssistantSettingsKeys.allKeys)
        XCTAssertTrue(intersection.isEmpty, "白名单混入了安全/缓存键: \(intersection)")
    }
}
