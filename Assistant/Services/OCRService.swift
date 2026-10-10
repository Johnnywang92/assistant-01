import Foundation
import UIKit
import Vision

/// 离线 OCR 服务：使用 iOS 系统自带 Vision 框架识别简体中文与英文
public final class OCRService: Sendable {
    public static let shared = OCRService()

    public init() {}

    /// 从 UIImage 提取识别到的文本行
    public func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let recognizedStrings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                let fullText = recognizedStrings.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }

            // 设置识别偏好：支持简体中文、繁体中文、英文
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum OCRError: LocalizedError {
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无效的图片格式或无法读取图像数据"
        }
    }
}
