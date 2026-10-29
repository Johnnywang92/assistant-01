/// 分享卡片的公共出口：离屏渲染与存入相册。
///
/// 各分享卡片此前各自复制了同一套 ImageRenderer → 相册写入的实现，
/// 差异只有成功文案。唤起系统面板统一走 `ShareActivityView`。
import Photos
import SwiftUI
import UIKit

@MainActor
enum ShareCardActions {
    /// 渲染失败的统一文案。
    static let renderFailureMessage = "生成图片失败，请重试"

    /// 3x 离屏渲染。
    /// `flattenAlpha` 会再压一层不透明画布，供对透明通道处理不佳的平台使用。
    static func render<Card: View>(
        _ card: Card,
        scale: CGFloat = 3,
        flattenAlpha: Bool = false
    ) -> UIImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        guard flattenAlpha else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// 存入相册，返回要展示给用户的文案：成功即 `successMessage`，失败给出原因。
    static func saveToPhotos(_ image: UIImage, successMessage: String) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Haptic.warning()
            return "请在系统设置中允许小助访问相册"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            Haptic.success()
            return successMessage
        } catch {
            Haptic.warning()
            return "保存失败：\(error.localizedDescription)"
        }
    }
}
