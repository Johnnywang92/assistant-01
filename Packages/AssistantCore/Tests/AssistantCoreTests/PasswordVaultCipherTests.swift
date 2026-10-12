import CryptoKit
import Foundation
import SwiftData
import XCTest

@testable import AssistantCore

/// 镜像 app 的 PasswordVaultItem（Core 看不到 app 类型）。
/// @Model 宏在 SwiftPM 测试目标下可用；必须放文件作用域——嵌套在测试类里时
/// 数组到 `[any PasswordVaultRecord]` 的转换拿不到协议一致性。
@Model
final class ForensicPasswordItem {
    var title: String
    var passwordEncrypted: String
    init(title: String, passwordEncrypted: String) {
        self.title = title
        self.passwordEncrypted = passwordEncrypted
    }
}

extension ForensicPasswordItem: PasswordVaultRecord {}

/// 密码库加密核心测试。重点：
/// ① 格式与往返保真；② 错误密钥/篡改必须失败；③ 迁移只搬明文且幂等；
/// ④ **取证测试**：迁移后持久化文件里搜不到原始密码（P0-2 验收核心）。
final class PasswordVaultCipherTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    // MARK: - 往返与格式

    func testEncryptDecryptRoundTrip() throws {
        let secret = "Tr0ub4dor&3"
        let stored = try PasswordVaultCipher.encrypt(secret, using: key)

        XCTAssertTrue(stored.hasPrefix(PasswordVaultCipher.prefix))
        XCTAssertFalse(stored.contains(secret))
        // 前缀之后必须是合法 base64（combined = nonce + ciphertext + tag）
        let payload = String(stored.dropFirst(PasswordVaultCipher.prefix.count))
        XCTAssertNotNil(Data(base64Encoded: payload))

        XCTAssertEqual(try PasswordVaultCipher.decrypt(stored, using: key), secret)
    }

    func testCiphertextIsNonDeterministic() throws {
        // 同一明文两次加密必须不同（随机 nonce），否则重复密文会泄露「两个账号同一密码」
        let a = try PasswordVaultCipher.encrypt("same", using: key)
        let b = try PasswordVaultCipher.encrypt("same", using: key)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try PasswordVaultCipher.decrypt(a, using: key), "same")
        XCTAssertEqual(try PasswordVaultCipher.decrypt(b, using: key), "same")
    }

    func testEmptyPasswordRoundTrip() throws {
        let stored = try PasswordVaultCipher.encrypt("", using: key)
        XCTAssertEqual(try PasswordVaultCipher.decrypt(stored, using: key), "")
    }

    func testUnicodePasswordRoundTrip() throws {
        let secret = "密码🔐パスワード"
        let stored = try PasswordVaultCipher.encrypt(secret, using: key)
        XCTAssertEqual(try PasswordVaultCipher.decrypt(stored, using: key), secret)
    }

    // MARK: - 失败路径

    func testDecryptWithWrongKeyFails() throws {
        let stored = try PasswordVaultCipher.encrypt("secret", using: key)
        var threw = false
        do {
            _ = try PasswordVaultCipher.decrypt(stored, using: SymmetricKey(size: .bits256))
        } catch {
            threw = true
        }
        XCTAssertTrue(threw) // 密钥不对必须失败，不能返回垃圾明文
    }

    func testTamperedCiphertextFails() throws {
        let stored = try PasswordVaultCipher.encrypt("secret", using: key)
        let payload = String(stored.dropFirst(PasswordVaultCipher.prefix.count))
        var bytes = try XCTUnwrap(Data(base64Encoded: payload))
        bytes[bytes.count - 1] ^= 0xFF // 破坏 tag
        let tampered = PasswordVaultCipher.prefix + bytes.base64EncodedString()

        var threw = false
        do {
            _ = try PasswordVaultCipher.decrypt(tampered, using: key)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw) // GCM 完整性校验：任何字节改动都必须被发现
    }

    func testMalformedBase64Fails() throws {
        var threw = false
        do {
            _ = try PasswordVaultCipher.decrypt(PasswordVaultCipher.prefix + "!!!not-base64!!!", using: key)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw)
    }

    // MARK: - 旧版明文兼容

    func testLegacyPlaintextPassesThrough() throws {
        // 无前缀 = 旧版明文：decrypt 原样返回（仅供迁移读取）
        XCTAssertEqual(try PasswordVaultCipher.decrypt("legacy-plain-123", using: key), "legacy-plain-123")
    }

    func testNeedsMigrationClassification() {
        XCTAssertTrue(PasswordVaultCipher.needsMigration("plain"))
        XCTAssertFalse(PasswordVaultCipher.needsMigration("aesgcm:v1:AAAA"))
        XCTAssertFalse(PasswordVaultCipher.needsMigration("")) // 空串不迁移：不给脏数据白造密文
    }

    // MARK: - 批量迁移

    private final class FakeRecord: PasswordVaultRecord {
        var passwordEncrypted: String
        init(_ value: String) { passwordEncrypted = value }
    }

    func testMigrateOnlyPlaintextAndIsIdempotent() throws {
        let cipher = try PasswordVaultCipher.encrypt("already-safe", using: key)
        let records = [
            FakeRecord("plain-1"),
            FakeRecord(cipher),   // 已是密文
            FakeRecord("plain-2"),
            FakeRecord("")        // 空串跳过
        ]

        let migrated = try PasswordVaultCipher.migrate(records, using: key)
        XCTAssertEqual(migrated, 2)
        XCTAssertTrue(records[0].passwordEncrypted.hasPrefix(PasswordVaultCipher.prefix))
        XCTAssertEqual(records[1].passwordEncrypted, cipher) // 密文记录原样不动
        XCTAssertTrue(records[2].passwordEncrypted.hasPrefix(PasswordVaultCipher.prefix))
        XCTAssertEqual(records[3].passwordEncrypted, "")

        // 幂等：再跑一次零迁移，且不会把密文二次加密
        XCTAssertEqual(try PasswordVaultCipher.migrate(records, using: key), 0)
        XCTAssertEqual(try PasswordVaultCipher.decrypt(records[0].passwordEncrypted, using: key), "plain-1")
        XCTAssertEqual(try PasswordVaultCipher.decrypt(records[2].passwordEncrypted, using: key), "plain-2")
    }

    // MARK: - SQLite 文件层清理

    func testPurgeOnMissingStoreSucceeds() {
        // 没有库文件 = 没有残留可清，应算成功（不能害调用方反复重试）
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pwd_missing_\(UUID().uuidString).store")
        XCTAssertTrue(SQLiteMaintenance.purgeResidualPlaintext(storeURL: missing))
    }

    // MARK: - 取证：持久化文件不得含明文

    func testPersistedStoreContainsNoPlaintext() throws {
        // 一个高辨识度密码：大小写+数字+符号，避免误命中
        let secret = "Zx9!qW7#mK2p"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pwd_forensic_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("forensic.store")
        let schema = Schema([ForensicPasswordItem.self])
        let config = ModelConfiguration("forensic", schema: schema, url: storeURL)

        // 1. 写入旧版明文记录（模拟升级前的库）
        let writeContainer = try ModelContainer(for: schema, configurations: config)
        let writeCtx = ModelContext(writeContainer)
        writeCtx.insert(ForensicPasswordItem(title: "公司邮箱", passwordEncrypted: secret))
        try writeCtx.save()

        // 2. 迁移：明文 → 密文
        let items = try writeCtx.fetch(FetchDescriptor<ForensicPasswordItem>())
        XCTAssertEqual(try PasswordVaultCipher.migrate(items, using: key), 1)
        try writeCtx.save()

        // 3a. 清理前先扫一遍：SQLite 的 UPDATE 不擦旧字节，明文此刻仍在磁盘上
        // （这一条是「问题确实存在」的证据；真正硬断言在清理之后）
        let residueBefore = scan(for: secret, in: [storeURL, dir.appendingPathComponent("forensic.store-wal")])
        print("· 清理前磁盘残留明文：\(residueBefore ? "有（SQLite UPDATE 不擦旧字节，符合预期）" : "无")")

        // 3b. 清除残留（与 app 迁移流程一致：迁移保存后必须做文件层清理）
        XCTAssertTrue(SQLiteMaintenance.purgeResidualPlaintext(storeURL: storeURL), "清理残留明文应成功")

        // 3c. 取证：再扫 .store 与 .store-wal 的原始字节（WAL 模式下数据可能还在 wal 里）
        let foundPlaintext = scan(for: secret, in: [storeURL, dir.appendingPathComponent("forensic.store-wal")])
        XCTAssertFalse(foundPlaintext) // 核心断言：磁盘上搜不到原始密码

        // 4. 重新打开库，记录仍可用原密钥解锁读取（VACUUM 不能把库弄坏）
        let readContainer = try ModelContainer(for: schema, configurations: config)
        let readCtx = ModelContext(readContainer)
        let restored = try readCtx.fetch(FetchDescriptor<ForensicPasswordItem>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(try PasswordVaultCipher.decrypt(restored[0].passwordEncrypted, using: key), secret)
    }

    /// 扫描候选文件的原始字节里是否出现给定明文（UTF-8 与 UTF-16 两种编码都查）
    private func scan(for plaintext: String, in urls: [URL]) -> Bool {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let bytes = try? Data(contentsOf: url) else { continue }
            if bytes.range(of: Data(plaintext.utf8)) != nil { return true }
            if let utf16 = plaintext.data(using: .utf16), bytes.range(of: utf16) != nil { return true }
        }
        return false
    }
}
