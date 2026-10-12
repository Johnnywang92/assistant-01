import Foundation
import SQLite3

/// SQLite 文件层维护。SwiftData 不暴露原始 SQL，但安全场景必须能下钻到磁盘文件。
public enum SQLiteMaintenance {

    /// 清除库文件里的残留明文。
    ///
    /// **背景（P0-2 取证测试发现的真问题）**：SQLite 的 UPDATE 不会擦除旧字节——
    /// 明文迁移成密文后，旧行原样留在空闲页里，直到页面被复用；WAL 文件里也存着
    /// 明文版本的旧帧。也就是说，只做「加密 + 保存」，磁盘取证照样能搜到原始密码。
    ///
    /// 清理手段：
    /// 1. `PRAGMA secure_delete = ON`——此后任何 UPDATE/DELETE 先零填充旧内容，
    ///    不只是打「空闲」标记（防的是用户以后改密码时产生新残留）；
    /// 2. `VACUUM`——重写整个库文件，空闲页连同其中的明文一起消失；
    /// 3. `PRAGMA wal_checkpoint(TRUNCATE)`——清掉 WAL 里的旧帧并截断文件。
    ///
    /// 最佳努力语义：库正被写入（SQLITE_BUSY）时返回 false 由调用方记「待清理」状态，
    /// 下次启动重试。清不掉不影响功能，但不能假装成功——明文还在磁盘上。
    @discardableResult
    public static func purgeResidualPlaintext(storeURL: URL) -> Bool {
        var handle: OpaquePointer?
        // 只读旧库已存在；不存在说明没库可清，直接算成功
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }

        let statements = [
            "PRAGMA secure_delete = ON;",
            "VACUUM;",
            "PRAGMA wal_checkpoint(TRUNCATE);"
        ]
        for statement in statements {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, statement, nil, nil, &errorMessage)
            if status != SQLITE_OK {
                if let errorMessage {
                    sqlite3_free(errorMessage)
                }
                // BUSY/LOCKED：库正在被写，稍后重试；其余错误同样视为本次未清干净
                return false
            }
        }
        return true
    }
}
