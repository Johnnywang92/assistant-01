import AssistantCore
import Foundation
import Security
import SwiftData
import UIKit

/// 负责将端到端强加密的备份同步至用户的 NAS 或私有云盘（WebDAV 协议）
@MainActor
final class WebDAVSyncService: ObservableObject {
    static let shared = WebDAVSyncService()

    private let configStorageKey = "webdav_sync_config_v1"
    private let keychainService = "com.yifanwang.assistant01.webdav"
    private let keychainAccount = "webdav_password"
    private let keychainAutoSyncPINAccount = "auto_sync_pin"

    @Published private(set) var config: WebDAVConfig
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastErrorMessage: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: configStorageKey),
           let saved = try? JSONDecoder().decode(WebDAVConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = WebDAVConfig()
        }
    }

    // MARK: - 配置与密码存储（密码加密进 Keychain）

    public func saveConfig(_ newConfig: WebDAVConfig, password: String? = nil) {
        self.config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: configStorageKey)
        }
        if let password, !password.isEmpty {
            saveSecret(password, account: keychainAccount)
        }
    }

    public func getPassword() -> String? {
        readSecret(account: keychainAccount)
    }

    public var hasPassword: Bool {
        !(readSecret(account: keychainAccount) ?? "").isEmpty
    }

    // MARK: - 自动备份口令（用户自设，只存本机钥匙串）

    /// 后台自动备份专用的用户口令。没有它后台就不上传，不存在任何内置兜底常量。
    public var autoSyncPIN: String? {
        let stored = readSecret(account: keychainAutoSyncPINAccount)
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    public var hasAutoSyncPIN: Bool {
        autoSyncPIN != nil
    }

    /// 设置或更换自动备份口令。强度校验沿用备份封套的规则，校验失败时保留原口令。
    /// 更换只影响之后的备份，已上传的文件仍需各自的旧口令。
    public func setAutoSyncPIN(_ pin: String) throws {
        let clean = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        try BackupEnvelopeCrypto.validatePin(clean)
        saveSecret(clean, account: keychainAutoSyncPINAccount)
    }

    // MARK: - WebDAV 核心能力

    /// 测试与 NAS / 云盘的连接状态
    public func testConnection() async throws -> String {
        guard config.isConfigured else {
            throw WebDAVError.missingConfiguration
        }
        guard let password = getPassword(), !password.isEmpty else {
            throw WebDAVError.missingPassword
        }
        guard let dirURL = WebDAVRequestFactory.makeDirectoryURL(
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory
        ) else {
            throw WebDAVError.invalidURL
        }

        let auth = WebDAVRequestFactory.makeAuthHeader(username: config.username, password: password)

        // 1. 尝试探测目录 PROPFIND
        let propfindReq = WebDAVRequestFactory.makePROPFINDRequest(url: dirURL, authHeader: auth)
        let (data, response) = try await URLSession.shared.data(for: propfindReq)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.networkFailure("非 HTTP 响应")
        }

        if httpResponse.statusCode == 207 || (200...299).contains(httpResponse.statusCode) {
            return "连接成功！已检测到远程备份目录。"
        } else if httpResponse.statusCode == 404 {
            // 目录不存在，尝试 MKCOL 创建目录
            let mkcolReq = WebDAVRequestFactory.makeMKCOLRequest(url: dirURL, authHeader: auth)
            let (_, mkcolRes) = try await URLSession.shared.data(for: mkcolReq)
            guard let mkcolHttp = mkcolRes as? HTTPURLResponse, (200...299).contains(mkcolHttp.statusCode) || mkcolHttp.statusCode == 201 else {
                throw WebDAVError.cannotCreateDirectory
            }
            return "连接成功！已自动在 NAS / 云盘上创建备份目录「\(config.remoteDirectory)」"
        } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw WebDAVError.authenticationFailed
        } else {
            throw WebDAVError.serverError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// 立即打包加密并上传备份至 NAS / 云盘
    @discardableResult
    func uploadBackup(
        pin: String,
        hint: String? = nil,
        context: ModelContext? = nil
    ) async throws -> (filename: String, formattedSize: String) {
        guard config.isConfigured else { throw WebDAVError.missingConfiguration }
        guard let password = getPassword(), !password.isEmpty else { throw WebDAVError.missingPassword }

        isSyncing = true
        lastErrorMessage = nil
        defer { isSyncing = false }

        let targetContext = context ?? Persistence.shared.mainContext

        // 1. 本地生成强加密备份包
        let migrationService = DataMigrationService(context: targetContext)
        let archive = try migrationService.exportEncryptedArchive(pin: pin, hint: hint)

        // 2. 检查或创建远端目录
        guard let dirURL = WebDAVRequestFactory.makeDirectoryURL(
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory
        ) else {
            throw WebDAVError.invalidURL
        }
        let auth = WebDAVRequestFactory.makeAuthHeader(username: config.username, password: password)

        // 预检或创建目录
        let mkcolReq = WebDAVRequestFactory.makeMKCOLRequest(url: dirURL, authHeader: auth)
        _ = try? await URLSession.shared.data(for: mkcolReq)

        // 3. 上传加密备份包 PUT
        guard let fileURL = WebDAVRequestFactory.makeFileURL(
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory,
            filename: archive.filename
        ) else {
            throw WebDAVError.invalidURL
        }

        let putReq = WebDAVRequestFactory.makePUTRequest(url: fileURL, data: archive.data, authHeader: auth)
        let (_, putRes) = try await URLSession.shared.data(for: putReq)
        guard let putHttp = putRes as? HTTPURLResponse, (200...299).contains(putHttp.statusCode) || putHttp.statusCode == 201 || putHttp.statusCode == 204 else {
            throw WebDAVError.uploadFailed
        }

        // 4. 更新同步记录
        var updated = config
        updated.lastSyncDate = .now
        updated.lastSyncStatus = "备份成功（\(archive.filename)）"
        saveConfig(updated)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeStr = formatter.string(fromByteCount: Int64(archive.data.count))

        return (archive.filename, sizeStr)
    }

    /// 列出 NAS / 云盘上的历史备份列表
    public func listRemoteBackups() async throws -> [WebDAVFileItem] {
        guard config.isConfigured else { throw WebDAVError.missingConfiguration }
        guard let password = getPassword(), !password.isEmpty else { throw WebDAVError.missingPassword }
        guard let dirURL = WebDAVRequestFactory.makeDirectoryURL(
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory
        ) else {
            throw WebDAVError.invalidURL
        }

        let auth = WebDAVRequestFactory.makeAuthHeader(username: config.username, password: password)
        let req = WebDAVRequestFactory.makePROPFINDRequest(url: dirURL, authHeader: auth)
        let (data, res) = try await URLSession.shared.data(for: req)

        guard let httpRes = res as? HTTPURLResponse, httpRes.statusCode == 207 || (200...299).contains(httpRes.statusCode) else {
            if let httpRes = res as? HTTPURLResponse, httpRes.statusCode == 404 {
                return []
            }
            throw WebDAVError.serverError("获取文件列表失败")
        }

        let allItems = WebDAVXMLParser.parseMultistatus(xmlData: data, baseURL: dirURL)

        // 只保留 .assistantbackup 后缀的加密备份文件。href 解析不出同源地址的条目直接丢弃：
        // 列出来也只会点出一条拒绝回执，反而像在邀请用户把凭据带出本机。
        let candidates = allItems.filter { $0.name.hasSuffix(".assistantbackup") && !$0.isCollection }
        let accepted = candidates.filter {
            WebDAVRequestFactory.makeFileURL(
                fromHref: $0.path,
                serverURL: config.serverURL,
                remoteDirectory: config.remoteDirectory
            ) != nil
        }
        if accepted.count < candidates.count {
            print("⚠️ [WebDAV] 已忽略 \(candidates.count - accepted.count) 条 href 与配置不同源/不在备份目录内的远端条目")
        }
        return accepted.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    /// 从 NAS / 云盘下载备份数据
    public func downloadBackup(item: WebDAVFileItem) async throws -> Data {
        guard let password = getPassword(), !password.isEmpty else { throw WebDAVError.missingPassword }

        // href 由服务器给出，不能直接信：只在同源且落在备份目录内时拼请求，跨源一律拒绝，
        // 否则 Basic 凭据会跟着这条 URL 发到第三方主机。
        guard let targetURL = WebDAVRequestFactory.makeFileURL(
            fromHref: item.path,
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory
        ) else {
            throw WebDAVError.rejectedRemoteHref
        }

        let auth = WebDAVRequestFactory.makeAuthHeader(username: config.username, password: password)
        let getReq = WebDAVRequestFactory.makeGETRequest(url: targetURL, authHeader: auth)
        let (data, res) = try await URLSession.shared.data(for: getReq)

        guard let httpRes = res as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            throw WebDAVError.downloadFailed
        }
        return data
    }

    /// 删除远端旧备份
    public func deleteRemoteBackup(item: WebDAVFileItem) async throws {
        guard let password = getPassword(), !password.isEmpty else { throw WebDAVError.missingPassword }
        // 用 href 而不是 displayname 拼路径：displayname 同样是服务器说了算，直接拼进
        // 删除请求会把「删一个备份」变成「删这台 NAS 上的任意路径」。
        guard let fileURL = WebDAVRequestFactory.makeFileURL(
            fromHref: item.path,
            serverURL: config.serverURL,
            remoteDirectory: config.remoteDirectory
        ) else {
            throw WebDAVError.rejectedRemoteHref
        }

        let auth = WebDAVRequestFactory.makeAuthHeader(username: config.username, password: password)
        let delReq = WebDAVRequestFactory.makeDELETERequest(url: fileURL, authHeader: auth)
        let (_, res) = try await URLSession.shared.data(for: delReq)

        guard let httpRes = res as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) || httpRes.statusCode == 204 else {
            throw WebDAVError.serverError("删除失败")
        }
    }

    /// 后台静默自动备份（在 BackgroundRefresh 巡检中被调用）
    public func performBackgroundSyncIfNeeded(context: ModelContext) async {
        guard config.autoSyncEnabled, config.isConfigured, hasPassword else { return }

        // 如果 20 小时内已经成功备份过，则避免频繁重复备份
        if let last = config.lastSyncDate, Date().timeIntervalSince(last) < 20 * 3600 {
            return
        }

        // 口令只认用户在设置页存进钥匙串的那一个。没设置就是「还没配好」，
        // 静默跳过，绝不用内置常量兜底——那样上传的文件等于没加密。
        guard let pin = autoSyncPIN else {
            print("⚠️ [WebDAV] 后台自动备份未执行：尚未设置自动备份口令")
            return
        }
        do {
            _ = try await uploadBackup(pin: pin, hint: "后台自动静默同步至NAS", context: context)
            print("☁️ [WebDAV] 后台自动同步备份至 NAS 成功")
        } catch {
            print("⚠️ [WebDAV] 后台自动同步备份失败: \(error)")
        }
    }

    // MARK: - Keychain 密码底层存储

    private func saveSecret(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteSecret(account: account)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readSecret(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteSecret(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - WebDAV 错误定义

public enum WebDAVError: LocalizedError {
    case missingConfiguration
    case missingPassword
    case invalidURL
    case rejectedRemoteHref
    case authenticationFailed
    case cannotCreateDirectory
    case uploadFailed
    case downloadFailed
    case serverError(String)
    case networkFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先配置 WebDAV 服务器地址与用户名"
        case .missingPassword:
            return "请输入 WebDAV 访问密码"
        case .invalidURL:
            return "服务器地址格式不正确，请以 http:// 或 https:// 开头"
        case .rejectedRemoteHref:
            return "远端返回的文件地址不在本机配置的服务器与备份目录内，已拒绝下载"
        case .authenticationFailed:
            return "WebDAV 账号或密码错误（HTTP 401/403）"
        case .cannotCreateDirectory:
            return "无法在远程服务器上创建备份目录，请检查 NAS 文件夹权限"
        case .uploadFailed:
            return "备份文件上传失败，请确认 NAS 磁盘空间或写入权限"
        case .downloadFailed:
            return "备份文件下载失败"
        case .serverError(let msg):
            return "服务器返回错误: \(msg)"
        case .networkFailure(let msg):
            return "网络通信异常: \(msg)"
        }
    }
}
