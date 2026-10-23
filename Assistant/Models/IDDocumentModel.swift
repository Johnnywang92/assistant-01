import Foundation
import ImageIO
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

    public var displayName: String { L10n.tr(rawValue) }

    /// 正面/首页提示
    public var frontSlotLabel: String {
        let raw: String = switch self {
        case .idCard: "人像面（正面）"
        case .driverLicense, .vehicleLicense: "正本/正页"
        case .passport: "个人信息页"
        case .bankCard: "卡号正面"
        case .realEstate, .businessLicense: "执照/证书页"
        default: "正面照片"
        }
        return L10n.tr(raw)
    }

    /// 反面/次页提示
    public var backSlotLabel: String {
        let raw: String = switch self {
        case .idCard: "国徽面（反面）"
        case .driverLicense, .vehicleLicense: "副页"
        case .passport: "签证/签名页"
        case .bankCard: "反面（含签名条）"
        default: "反面/补充页"
        }
        return L10n.tr(raw)
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
        guard let num = documentNumber, !num.isEmpty else { return L10n.tr("未录入号码") }
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
    private static let thumbnailCache = NSCache<NSString, UIImage>()

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

    /// 直接保存照片原始字节到私有沙盒（迁移还原时避免二次 JPEG 有损重编码）
    public static func saveData(_ data: Data, preferredName: String? = nil) -> String? {
        guard UIImage(data: data) != nil else { return nil }
        let fileName: String
        if let preferredName, !preferredName.isEmpty,
           !FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent(preferredName).path) {
            fileName = preferredName
        } else {
            fileName = "\(UUID().uuidString).jpg"
        }
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return fileName
        } catch {
            return nil
        }
    }

    /// 从本地沙盒读取原始照片字节（导出备份时免解码直读）
    public static func loadData(fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }

    /// 从本地沙盒读取完整照片
    public static func loadImage(fileName: String?) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    /// 高性能降采样读取缩略图，避免直接解码巨幅原图占用过多内存和阻塞主线程
    public static func loadThumbnail(fileName: String?, maxPixelSize: CGFloat = 360) -> UIImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let cacheKey = "\(fileName)_\(Int(maxPixelSize))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        let fileURL = storageDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, imageSourceOptions) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        let image = UIImage(cgImage: downsampledImage)
        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// 删除指定照片
    public static func deleteImage(fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        thumbnailCache.removeObject(forKey: "\(fileName)_360" as NSString)
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 清空全部证件照片与缩略图缓存（全量覆盖还原前清理旧残留）
    public static func deleteAllImages() {
        thumbnailCache.removeAllObjects()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// 清理未被引用的孤儿照片文件（在数据库事务成功提交后调用，保证回滚安全）
    public static func pruneUnreferenced(keeping validFileNames: Set<String>) {
        thumbnailCache.removeAllObjects()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !validFileNames.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
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
        context.localizedCancelTitle = L10n.tr("取消")
        var error: NSError?

        // 优先使用生物识别或系统锁屏密码
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L10n.tr(reason)) { success, authErr in
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
            #if targetEnvironment(simulator)
            self.isUnlocked = true
            #else
            let code = error.map { LAError(_nsError: $0).code }
            if code == .passcodeNotSet {
                self.isUnlocked = true
                self.errorMessage = nil
            } else {
                self.isUnlocked = false
                self.errorMessage = error?.localizedDescription ?? L10n.tr("当前无法验证身份，请稍后重试")
            }
            #endif
        }
    }

    /// 锁定保险箱
    public func lock() {
        self.isUnlocked = false
    }
}
