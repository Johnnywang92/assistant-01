import SwiftUI

// 分享卡族共享部件。
//
// 背景（审计 UI-02）：Health / Psych / Hydration / Report / Expense 五张卡是「模板级复制」，
// 其中「品牌落款」与「专属网站标识」两段在四张卡里逐字符相同，只有标题文案、颜色、
// 间距、阴影强度不同 —— 以前每张卡各存一份，改一处就要改四遍，已经出现漂移。
// 这里用参数注入差异，卡片本身只保留「数据 → 指标项」的映射。
//
// 注意：分享卡是 `ImageRenderer` 位图导出，**颜色必须由调用方传固定色板**，
// 这些组件内部不引用任何依赖环境/动态色的 AppColor。

/// 品牌落款：App 图标 + 主标题 + 副标题（记所想，助所行）。
struct ShareCardBrandIdentity: View {
    var title: String = "小助 · 个人智能生活助理"
    var titleColor: Color
    var subtitle: String = "记所想，助所行"
    var subtitleColor: Color
    /// 标题与副标题的行距（各卡历史上分别是 2 / 1.5）
    var titleSpacing: CGFloat = 2
    /// 图标阴影强度（亮底卡 0.12 / 暗底卡 0.2）
    var iconShadowOpacity: Double = 0.12

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("AssistantAppIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                .shadow(color: Color.black.opacity(iconShadowOpacity), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: titleSpacing) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
        }
    }
}

/// 专属网站标识胶囊（JohnnyBoyStudio）。
struct ShareCardStudioBadge: View {
    var tint: Color
    /// 底色透明度：Health 卡历史上用 0.12，Hydration/Report 用 0.18。
    var backgroundOpacity: Double = 0.18

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 9))
            Text("JohnnyBoyStudio")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(tint.opacity(backgroundOpacity))
        .foregroundStyle(tint)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.6)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}
