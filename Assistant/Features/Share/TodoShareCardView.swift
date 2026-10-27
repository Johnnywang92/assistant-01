/// 专为导出高清分享图设计的 SwiftUI 卡片视图（支持 3x 离屏光栅化）
///
/// 从 TodoShareSheet.swift 拆出：只负责渲染，不持有任何 UI 状态。
import AssistantCore
import Photos
import SwiftData
import SwiftUI
import UIKit

struct TodoShareCardView: View {
    let title: String
    let items: [TodoItem]
    let showWatermark: Bool
    let theme: ShareCardTheme
    var miniQRCode: UIImage? = nil

    // 双语 Slogan 定义
    static let sloganZh = "记所想，助所行"
    static let sloganEn = "Capture thoughts, empower actions."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. 卡片头部：日期与总览
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryTextColor)

                    Text(L10n.tr(title))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                }

                Spacer()

                // 完成进度胶囊
                let doneCount = items.filter { $0.status == .done }.count
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(doneCount)/\(items.count)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentColor)
                    Text("完成进度")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // 2. 清单列表条目
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.largeTitle)
                        .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    Text("请在下方列表中勾选要分享的事项")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                let displayItems = Array(items.prefix(15))
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(displayItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(item.status == .done ? (theme == .obsidian ? theme.accentColor : Color.green) : Color.secondary.opacity(0.6))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.tr(item.title))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(item.status == .done ? theme.secondaryTextColor : theme.textColor)
                                    .strikethrough(item.status == .done)

                                if let code = item.pickupCode {
                                    HStack(spacing: 4) {
                                        Text("取件码：\(code)")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        if let station = item.location ?? item.station {
                                            Text("(\(station))")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .foregroundStyle(Color.orange)
                                }
                            }

                            Spacer()
                        }
                    }

                    if items.count > 15 {
                        Text("… 更多 \(items.count - 15) 项事项")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                            .padding(.leading, 28)
                    }
                }
                .padding(.vertical, 2)
            }

            // 3. 底部 App Logo 与 Slogan 水印栏（可自由显隐）
            if showWatermark {
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(height: 1)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("小助")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.textColor)

                            Text("· 个人智能生活助理")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.secondaryTextColor)
                        }

                        // 双语 Slogan：记所想，助所行 / Capture thoughts, empower actions.
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.sloganZh)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accentColor)

                            Text(Self.sloganEn)
                                .font(.system(size: 9.5, weight: .regular))
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if let miniQRCode {
                            Image(uiImage: miniQRCode)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 38, height: 38)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                                )
                        }

                        Text("JohnnyBoyStudio")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme == .obsidian ? Color(red: 0.18, green: 0.85, blue: 0.48) : theme.secondaryTextColor)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 350)
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }
}
