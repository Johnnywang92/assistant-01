import Foundation
import LocalAuthentication
import SwiftData
import UIKit

/// 证件类型定义
public enum IDDocumentType: String, Codable, CaseIterable, Sendable {
    case idCard = "居民身份证"
    case passport = "护照"
    case driverLicense = "机动车驾驶证"
    case vehicleLicense = "机动车行驶证"
    case residencePermit = "港澳台/居住证"
    case socialSecurity = "社保卡/医保卡"
    case bankCard = "银行卡"
    case businessLicense = "营业执照"
    case realEstate = "房产/不动产权证"
    case degree = "毕业证/学位证"
    case other = "其它重要凭证"

    public var icon: String {
        switch self {
        case .idCard: return "person.text.rectangle.fill"
        case .passport: return "book.closed.fill"
        case .driverLicense: return "car.fill"
        case .vehicleLicense: return "car.rear.fill"
        case .residencePermit: return "globe.asia.australia.fill"
        case .socialSecurity: return "cross.case.fill"
        case .bankCard: return "creditcard.fill"
        case .businessLicense: return "building.2.fill"
        case .realEstate: return "house.fill"
        case .degree: return "graduationcap.fill"
        case .other: return "doc.text.image.fill"
        }
    }

    /// 正面/首页提示
    public var frontSlotLabel: String {
        switch self {
        case .idCard: return "人像面（正面）"
        case .driverLicense, .vehicleLicense: return "正本/正页"
        case .passport: return "个人信息页"
        case .bankCard: return "卡号正面"
        case .realEstate, .businessLicense: return "执照/证书页"
        default: return "正面照片"
        }
    }

    /// 反面/次页提示
    public var backSlotLabel: String {
        switch self {
        case .idCard: return "国徽面（反面）"
        case .driverLicense, .vehicleLicense: return "副页"
        case .passport: return "签证/签名页"
        case .bankCard: return "反面（含签名条）"
        default: return "反面/补充页"
        }
    }
}

/// 重要证件与照片保险箱存储模型
@Model
public final class IDDocumentItem {
    public var id: UUID
    public var title: String                // 证件标题，如 "本人身份证", "妻子护照"
    public var typeRaw: String              // IDDocumentType.rawValue
    public var holderName: String?          // 姓名 / 持有人
    public var documentNumber: String?      // 证件号码（方便日常填表一键复制）
    public var expiryDate: Date?            // 有效期截止日（到期前预警）
    public var isPermanent: Bool            // 是否长期有效（如身份证长期）
    public var frontImageFileName: String?  // 沙盒中存储的正面照片文件名
    public var backImageFileName: String?   // 沙盒中存储的反面照片文件名
    public var notes: String?               // 补充备注（签发地、签发机关等）
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        title: String,
        type: IDDocumentType = .idCard,
        holderName: String? = nil,
        documentNumber: String? = nil,
        expiryDate: Date? = nil,
        isPermanent: Bool = false,
        frontImageFileName: String? = nil,
        backImageFileName: String? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.typeRaw = type.rawValue
        self.holderName = holderName
        self.documentNumber = documentNumber
        self.expiryDate = isPermanent ? nil : expiryDate
        self.isPermanent = isPermanent
        self.frontImageFileName = frontImageFileName
        self.backImageFileName = backImageFileName
        self.notes = notes
        self.createdAt = .now
        self.updatedAt = .now
    }

    public var type: IDDocumentType {
        get { IDDocumentType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    /// 距离过期的天数（如果是长期有效则为 nil）
    public var daysUntilExpiry: Int? {
        guard !isPermanent, let expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: expiryDate).day
    }

    /// 是否临期（30天内到期）
    public var isExpiringSoon: Bool {
        guard let days = daysUntilExpiry else { return false }
        return days >= 0 && days <= 30
    }

    /// 是否已过期
    public var isExpired: Bool {
        guard let days = daysUntilExpiry else { return false }
        return days < 0
    }

    /// 脱敏显示的证件号码（如 3101**********1234）
    public var maskedNumber: String {
        guard let num = documentNumber, !num.isEmpty else { return "未录入号码" }
        if num.count <= 6 { return num }
        let prefixCount = min(4, num.count / 3)
        let suffixCount = min(4, num.count / 3)
        let middleCount = num.count - prefixCount - suffixCount
        let prefix = num.prefix(prefixCount)
        let suffix = num.suffix(suffixCount)
        return "\(prefix)\(String(repeating: "*", count: middleCount))\(suffix)"
    }
}

/// 证件照片本地沙盒持久化安全存储
public enum IDPhotoStorage {
    private static var storageDirectory: URL {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL.documentsDirectory
        let dir = baseDir.appendingPathComponent("IDVaultPhotos", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 保存照片数据到私有沙盒，返回生成的文件名（应用系统级硬件加密保护）
    public static func saveImage(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.88) else { return nil }
        let fileName = "\(UUID().uuidString).jpg"
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return fileName
        } catch {
            return nil
        }
    }

    /// 从本地沙盒读取照片
    public static func loadImage(fileName: String?) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    /// 删除指定照片
    public static func deleteImage(fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Face ID / Touch ID / 锁屏密码安全鉴权管理器
@MainActor
public final class BiometricAuthManager: ObservableObject {
    public static let shared = BiometricAuthManager()

    @Published public var isUnlocked: Bool = false
    @Published public var errorMessage: String?

    public init() {}

    /// 发起生物识别或锁屏密码校验
    public func authenticate(reason: String = "验证身份以解锁查看重要证件照片") {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?

        // 优先使用生物识别或系统锁屏密码
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authErr in
                Task { @MainActor in
                    if success {
                        self.isUnlocked = true
                        self.errorMessage = nil
                    } else {
                        self.errorMessage = authErr?.localizedDescription
                    }
                }
            }
        } else {
            // 设备未设密码或模拟器环境：直接放行
            self.isUnlocked = true
        }
    }

    /// 锁定保险箱
    public func lock() {
        self.isUnlocked = false
    }
}
