/// 分享卡片的公共出口：离屏渲染与存入相册。
///
/// 各分享卡片此前各自复制了同一套 ImageRenderer → 相册写入的实现，
/// 差异只有成功文案。唤起系统面板统一走 `ShareActivityView`。
///
/// **产品口径：永远只出一张完整长图。**
/// 长笔记通过降低渲染倍率把整张图压进位图上限，不分页、不切片、不折叠内容。
import AssistantCore
import Photos
import SwiftUI
import UIKit

@MainActor
enum ShareCardActions {
    /// 渲染失败的统一文案。
    static let renderFailureMessage = "生成图片失败，请重试"

    /// 位图任一边的像素上限（px）。iOS 的 CoreGraphics / Metal 纹理在超大画布上
    /// 会静默返回被裁切的图——这正是「相册里只剩中间一段、头尾都丢」的成因。
    /// 倍率规则下沉在 Core（可单测），这里只做调用。
    static let maxPixelSide: CGFloat = CGFloat(ShareCardRenderScale.maxPixelSide)

    /// 离屏渲染成**一张**图片。
    ///
    /// - Parameter estimatedHeight: 卡片估算高度（pt）。传了就先算安全倍率再渲染，
    ///   **绝不先渲一张 3x 超尺寸图再降级**——那一次超尺寸渲染本身就是残图来源。
    /// - Parameter flattenAlpha: 再压一层不透明画布。长图会额外吃一倍内存，
    ///   语音笔记分享卡不启用；卡片本身已有实心背景。
    static func render<Card: View>(
        _ card: Card,
        scale: CGFloat = 3,
        estimatedHeight: CGFloat? = nil,
        flattenAlpha: Bool = false
    ) -> UIImage? {
        func makeImage(at requestedScale: CGFloat) -> UIImage? {
            let renderer = ImageRenderer(content: card)
            renderer.scale = requestedScale
            return renderer.uiImage
        }

        let effectiveScale: CGFloat
        if let estimatedHeight, estimatedHeight > 0 {
            effectiveScale = CGFloat(ShareCardRenderScale.safeScale(
                longestSide: Double(estimatedHeight),
                preferred: Double(scale)
            ))
        } else {
            effectiveScale = scale
        }

        guard var image = makeImage(at: effectiveScale) else { return nil }

        // 渲染后核对实际像素：估算可能偏低，系统也可能悄悄缩过图。
        // 越界时再降一档重试；仍不行就明确失败，不输出残图。
        if !ShareCardRenderScale.isWithinLimit(
            points: Double(max(image.size.width, image.size.height)),
            scale: Double(image.scale)
        ) {
            let fallback = max(1, effectiveScale - 1)
            guard fallback < effectiveScale,
                  let smaller = makeImage(at: fallback),
                  ShareCardRenderScale.isWithinLimit(
                      points: Double(max(smaller.size.width, smaller.size.height)),
                      scale: Double(smaller.scale)
                  ) else { return nil }
            image = smaller
        }

        guard flattenAlpha else { return image }

        // 用 image.scale 而不是入参 scale：降过 scale 后两者已不同，
        // 写成入参会得到尺寸不一致的二次画布，图片会被悄悄放大或裁掉。
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
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
