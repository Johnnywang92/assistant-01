import CryptoKit
import Foundation
import XCTest

@testable import AssistantCore

/// 备份封套加密测试（P0-4 验收：新备份可解密、错误口令失败、旧备份仍能按原格式导入）。
/// 覆盖：往返、错误口令、篡改、迭代边界、v1 HKDF 兼容、盐随机性、口令长度策略。
final class BackupEnvelopeCryptoTests: XCTestCase {
    private let goodPin = "correct-horse-battery"
    private let salt = BackupEnvelopeCrypto.makeSalt()

    // MARK: - 新格式（v2 / PBKDF2）往返

    func testSealOpenRoundTrip() throws {
        let payload = Data("{\"todos\":[{\"title\":\"买牛奶\"}]}".utf8)
        let sealed = try BackupEnvelopeCrypto.seal(payload, pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)

        XCTAssertNotEqual(sealed, payload) // 确实是密文
        let opened = try BackupEnvelopeCrypto.open(sealed, pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        XCTAssertEqual(opened, payload)
    }

    func testOpenPayloadDispatchesByVersion() throws {
        let payload = Data("v2-payload".utf8)
        let sealed = try BackupEnvelopeCrypto.seal(payload, pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)

        // v2 显式迭代次数
        let a = try BackupEnvelopeCrypto.openPayload(version: 2, payload: sealed, pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        XCTAssertEqual(a, payload)
        // v2 迭代次数缺失时回退默认值（老版本 App 没写 iterations 字段）
        let b = try BackupEnvelopeCrypto.openPayload(version: 2, payload: sealed, pin: goodPin, salt: salt, iterations: nil)
        XCTAssertEqual(b, payload)
    }

    func testWrongPassphraseFails() throws {
        let sealed = try BackupEnvelopeCrypto.seal(Data("secret".utf8), pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)

        var threw = false
        do {
            _ = try BackupEnvelopeCrypto.open(sealed, pin: "wrong-passphrase", salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        } catch let error as BackupEnvelopeCrypto.BackupCryptoError {
            threw = true
            XCTAssertEqual(error, .authenticationFailed)
        }
        XCTAssertTrue(threw)
    }

    func testTamperedPayloadFails() throws {
        let sealed = try BackupEnvelopeCrypto.seal(Data("secret".utf8), pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01

        var threw = false
        do {
            _ = try BackupEnvelopeCrypto.open(tampered, pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw) // 改一个 bit 都必须发现
    }

    func testWrongSaltFails() throws {
        // 盐错了 = 密钥错了（同一口令 + 不同盐 → 不同密钥）
        let sealed = try BackupEnvelopeCrypto.seal(Data("secret".utf8), pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        var threw = false
        do {
            _ = try BackupEnvelopeCrypto.open(sealed, pin: goodPin, salt: BackupEnvelopeCrypto.makeSalt(), iterations: BackupEnvelopeCrypto.defaultIterations)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw)
    }

    // MARK: - 迭代次数策略

    func testIterationsBoundsEnforced() throws {
        XCTAssertThrowsError(try BackupEnvelopeCrypto.seal(Data("x".utf8), pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.minIterations - 1)) { error in
            XCTAssertEqual(error as? BackupEnvelopeCrypto.BackupCryptoError, .invalidIterations)
        }
        // 下限本身合法（慢 KDF 的意义：别让“迭代 1 次”的封套被瞬间解开）
        _ = try BackupEnvelopeCrypto.seal(Data("x".utf8), pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.minIterations)

        var threwUpper = false
        do {
            _ = try BackupEnvelopeCrypto.deriveKey(pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.maxIterations + 1)
        } catch let error as BackupEnvelopeCrypto.BackupCryptoError {
            threwUpper = true
            XCTAssertEqual(error, .invalidIterations)
        }
        XCTAssertTrue(threwUpper)
    }

    func testDefaultIterationsWithinBounds() {
        XCTAssertTrue((BackupEnvelopeCrypto.minIterations...BackupEnvelopeCrypto.maxIterations).contains(BackupEnvelopeCrypto.defaultIterations))
    }

    func testDerivationIsDeterministicAndSaltSensitive() throws {
        let key1 = try BackupEnvelopeCrypto.deriveKey(pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        let key2 = try BackupEnvelopeCrypto.deriveKey(pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations)
        let key3 = try BackupEnvelopeCrypto.deriveKey(pin: goodPin, salt: BackupEnvelopeCrypto.makeSalt(), iterations: BackupEnvelopeCrypto.defaultIterations)
        let key4 = try BackupEnvelopeCrypto.deriveKey(pin: goodPin, salt: salt, iterations: BackupEnvelopeCrypto.minIterations)

        XCTAssertEqual(bytes(key1), bytes(key2))              // 同输入同输出
        XCTAssertNotEqual(bytes(key1), bytes(key3))           // 换盐换密钥
        XCTAssertNotEqual(bytes(key1), bytes(key4))           // 换迭代次数也换密钥
    }

    // MARK: - v1 遗留格式兼容

    func testLegacyV1EnvelopeStillOpens() throws {
        // 按 v1 的方式手工封一份：HKDF 派生 + AES-GCM
        let payload = Data("legacy-backup-content".utf8)
        let legacyKey = BackupEnvelopeCrypto.deriveLegacyKey(pin: "1234", salt: salt) // v1 允许 4 位 PIN
        let sealed = try AES.GCM.seal(payload, using: legacyKey).combined

        let opened = try BackupEnvelopeCrypto.openPayload(version: 1, payload: XCTUnwrap(sealed), pin: "1234", salt: salt, iterations: nil)
        XCTAssertEqual(opened, payload)

        // v1 也必须是「错口令失败」
        var threw = false
        do {
            _ = try BackupEnvelopeCrypto.openPayload(version: 1, payload: XCTUnwrap(sealed), pin: "4321", salt: salt, iterations: nil)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw)
    }

    func testUnsupportedVersionRejected() {
        var threw = false
        do {
            _ = try BackupEnvelopeCrypto.openPayload(version: 99, payload: Data(), pin: goodPin, salt: salt, iterations: nil)
        } catch let error as BackupEnvelopeCrypto.BackupCryptoError {
            threw = true
            XCTAssertEqual(error, .unsupportedVersion)
        } catch {
            XCTFail("应抛 unsupportedVersion，实际：\(error)")
        }
        XCTAssertTrue(threw)
    }

    // MARK: - 口令长度策略

    func testPinLengthPolicy() throws {
        XCTAssertThrowsError(try BackupEnvelopeCrypto.validatePin(String(repeating: "a", count: 7))) { error in
            XCTAssertEqual(error as? BackupEnvelopeCrypto.BackupCryptoError, .pinOutOfRange)
        }
        XCTAssertThrowsError(try BackupEnvelopeCrypto.validatePin(String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(error as? BackupEnvelopeCrypto.BackupCryptoError, .pinOutOfRange)
        }
        try BackupEnvelopeCrypto.validatePin(String(repeating: "a", count: 8))   // 下限放行
        try BackupEnvelopeCrypto.validatePin(String(repeating: "a", count: 64))  // 上限放行

        // seal 同样守长度：短口令根本不能产出备份
        XCTAssertThrowsError(try BackupEnvelopeCrypto.seal(Data("x".utf8), pin: "short", salt: salt, iterations: BackupEnvelopeCrypto.defaultIterations))
    }

    // MARK: - 盐

    func testSaltIsRandomPerCall() {
        let a = BackupEnvelopeCrypto.makeSalt()
        let b = BackupEnvelopeCrypto.makeSalt()
        XCTAssertNotEqual(a, b)          // 两份备份即使用同一口令，盐也不同
        XCTAssertEqual(a.count, 32)      // 256-bit
    }

    private func bytes(_ key: SymmetricKey) -> [UInt8] {
        key.withUnsafeBytes { Array($0) }
    }
}
