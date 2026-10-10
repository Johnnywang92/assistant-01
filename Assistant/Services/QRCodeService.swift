import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// 面对面/跨设备分享的数据传输载荷
public struct SharedTodoDTO: Codable, Identifiable {
    public var id: String { "\(t)_\(due ?? 0)_\(pc ?? "")" }
    public var t: String                // title
    public var ty: String               // type rawValue (TodoType)
    public var d: String?               // detail
    public var pc: String?              // pickupCode
    public var loc: String?             // location / station
    public var courier: String?         // courier name
    public var due: TimeInterval?       // due timestamp (timeIntervalSince1970)

    public init(
        title: String,
        type: String,
        detail: String? = nil,
        pickupCode: String? = nil,
        location: String? = nil,
        courier: String? = nil,
        due: Date? = nil
    ) {
        self.t = title
        self.ty = type
        self.d = detail
        self.pc = pickupCode
        self.loc = location
        self.courier = courier
        self.due = due?.timeIntervalSince1970
    }
}

public struct TodoSharePayload: Codable, Identifiable {
    public var id: String { "\(title)_\(createdAt)" }
    public var v: Int                   // 版本号，初始为 1
    public var title: String            // 清单标题
    public var items: [SharedTodoDTO]   // 待办条目列表
    public var createdAt: TimeInterval  // 生成时间戳

    public init(title: String, items: [SharedTodoDTO]) {
        self.v = 1
        self.title = title
        self.items = items
        self.createdAt = Date().timeIntervalSince1970
    }
}

/// 二维码生成、解析与数据打包引擎
public enum QRCodeService {

    // MARK: - 载荷编码与 URL Scheme 封装

    /// 将选中的待办事项编码为 assistant://import?d=... 协议字符串
    static func encodePayload(title: String, todos: [TodoItem]) -> String {
        let dtos = todos.map { item in
            SharedTodoDTO(
                title: item.title,
                type: item.typeRaw,
                detail: item.detail,
                pickupCode: item.pickupCode,
                location: item.location ?? item.station,
                courier: item.courier,
                due: item.dueAt
            )
        }

        let payload = TodoSharePayload(title: title, items: dtos)
        guard let jsonData = try? JSONEncoder().encode(payload) else {
            return "assistant://import"
        }

        // 使用 Base64 URL-safe 编码，紧凑安全
        let base64 = jsonData.base64EncodedString()
        guard let encoded = base64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "assistant://import?d=\(base64)"
        }
        return "assistant://import?d=\(encoded)"
    }

    /// 从扫描字符串或 URL 中解析出待办数据载荷
    public static func decodePayload(from rawString: String) -> TodoSharePayload? {
        var base64Content: String = rawString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 若为 assistant://import?d=... 或 assistant://... URL 格式
        if let url = URL(string: base64Content), let scheme = url.scheme?.lowercased(), scheme == "assistant" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let dParam = components.queryItems?.first(where: { $0.name == "d" || $0.name == "data" })?.value {
                    base64Content = dParam
                }
            }
        }

        // 尝试 URL Decode
        if let decodedStr = base64Content.removingPercentEncoding {
            base64Content = decodedStr
        }

        // 2. 尝试从 Base64 解析 JSON
        if let data = Data(base64Encoded: base64Content),
           let payload = try? JSONDecoder().decode(TodoSharePayload.self, from: data) {
            return payload
        }

        // 3. 兜底直接尝试纯 JSON 文本解析
        if let data = base64Content.data(using: .utf8),
           let payload = try? JSONDecoder().decode(TodoSharePayload.self, from: data) {
            return payload
        }

        return nil
    }

    // MARK: - 原生高清矢量级二维码图片生成 (CoreImage)

    public static func generateQRCode(from text: String, targetSize: CGFloat = 380) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        // M 级别容错率（约 15%），兼顾扫码极速响应与清晰度
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputCIImage = filter.outputImage else { return nil }

        let extent = outputCIImage.extent
        let scale = targetSize / extent.width
        let transformed = outputCIImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - 从相册 UIImage 识别二维码 (CoreImage Detector)

    public static func detectQRCode(from image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )

        let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] ?? []
        return features.first?.messageString
    }
}
