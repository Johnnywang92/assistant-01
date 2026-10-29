/// 分享展示形式与面对面扫码卡片
///
/// 从 TodoShareSheet.swift 拆出：展示形式枚举与二维码卡片视图放在一起，
/// 它们只在「二维码」这条分支里成对使用。
import AssistantCore
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 分享展示形式
enum ShareFormatMode: String, CaseIterable, Identifiable {
    case qrCode = "面对面二维码"
    case poster = "海报长图卡片"

    var id: String { rawValue }
}

/// 专为面对面扫码设计的二维码分享卡片
struct TodoQRCodeCardView: View {
    let title: String
    let items: [TodoItem]
    let qrImage: UIImage?

    var body: some View {
        VStack(spacing: 14) {
            // 顶部 App 标志与标语
            HStack(spacing: 10) {
                Image("AssistantAppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("小助 · 面对面扫码导入")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.primary)
                    }

                    Text("记所想，助所行 · Capture thoughts, empower actions.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }

            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1)

            // 清单标题与条目统计
            VStack(spacing: 4) {
                Text(L10n.tr(title))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text("已打包 \(items.count) 项待办事宜，扫码一键同步至手机")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }

            // 高清二维码
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 210, height: 210)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("请在下方勾选待办生成二维码")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .frame(width: 210, height: 210)
            }

            // 引导提示胶囊
            HStack(spacing: 6) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                Text("其他用户打开小助扫一扫，或使用系统相机直接扫描")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(Capsule())
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
                .strokeBorder(Color(.systemGray5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }
}
