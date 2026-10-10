import Foundation
import SwiftData

/// 密码项存储模型（支持离线密码安全管理、强度评估、轮换周期预警）
@Model
public final class PasswordVaultItem {
    public var id: UUID
    public var title: String               // 服务/账号名称，如 "公司企业邮箱", "路由器管理", "Apple ID"
    public var account: String             // 账号/用户名/邮箱
    public var passwordEncrypted: String   // aesgcm:v1: 前缀的密文；旧版记录迁移时可能为明文
    public var category: String            // 分类：工作/日常/银行资产/服务器设备
    public var notes: String?              // 补充提示/安全问题备忘
    public var lastRotatedAt: Date         // 上次更换密码的时间
    public var rotateCycleDays: Int        // 密码建议更新周期（天，默认 90 天，0 表示不强制更新）

    public init(
        title: String,
        account: String,
        passwordEncrypted: String,
        category: String = "日常账号",
        notes: String? = nil,
        lastRotatedAt: Date = .now,
        rotateCycleDays: Int = 90
    ) {
        self.id = UUID()
        self.title = title
        self.account = account
        self.passwordEncrypted = passwordEncrypted
        self.category = category
        self.notes = notes
        self.lastRotatedAt = lastRotatedAt
        self.rotateCycleDays = rotateCycleDays
    }

    /// 距离下次建议更换密码的到期时间
    public var nextRotationDueDate: Date? {
        guard rotateCycleDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: rotateCycleDays, to: lastRotatedAt)
    }

    /// 密码已使用天数
    public var usedDays: Int {
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: lastRotatedAt, to: .now).day ?? 0)
    }

    /// 是否已到达或超过建议轮换周期
    public var isRotationDue: Bool {
        guard rotateCycleDays > 0 else { return false }
        return usedDays >= rotateCycleDays
    }
}
