import AssistantCore
import SwiftData
import SwiftUI
import UIKit

// MARK: - Apple Wallet 风格收纳物品卡片

struct StoredItemWalletCard: View {
    let item: StoredItem
    var linkedExpenseTotal: Double = 0
    var isExpanded: Bool = false
    var onPreviewImage: ((Data) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var theme: StorageRoomCardTheme {
        StorageRoomCardTheme.theme(for: item.roomArea)
    }

    private var costSummary: ItemCostSummary {
        ItemCostCalculator.summary(
            purchasePrice: item.purchasePrice,
            purchaseDate: item.purchaseDate,
            fallbackStartDate: item.createdAt,
            linkedExpenseTotal: linkedExpenseTotal,
            isSecondHand: item.isSecondHand,
            resalePrice: item.resalePrice,
            resoldDate: item.resoldDate
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 卡片主体
            ZStack(alignment: .topLeading) {
                // 背景渐变
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .fill(theme.backgroundGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 4)

                // 若有图片，背景可有微弱照片虚化光晕
                if let data = item.imageData, let img = RowThumbnailCache.thumbnail(id: item.id, updatedAt: item.updatedAt, data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipped()
                        .opacity(0.14)
                        .blur(radius: 12)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
                }

                // 卡面正文
                VStack(alignment: .leading, spacing: 12) {
                    // 1. 顶部：房间区域标签 + 状态徽标 + 门禁/钥匙图标
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: theme.iconName)
                                .font(.caption.bold())
                            Text(L10n.tr(item.roomArea))
                                .font(.caption.bold())
                        }
                        .foregroundStyle(theme.tagColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.black.opacity(0.35))
                        )

                        if item.isSecondHand {
                            Text("二手")
                                .font(.caption2.bold())
                                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.8))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.3)))
                        }

                        if costSummary.isResold {
                            Text("已转卖")
                                .font(.caption2.bold())
                                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.3)))
                        }

                        Spacer()

                        Image(systemName: "shippingbox.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    // 2. 中间：物品大名 + 缩略图（若有）
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            // 关键存放位置
                            HStack(spacing: 5) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.caption.bold())
                                    .foregroundStyle(theme.tagColor)
                                Text(item.location)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(2)
                            }
                        }

                        Spacer()

                        // 实物照片缩略图
                        if let data = item.imageData, let img = RowThumbnailCache.thumbnail(id: item.id, updatedAt: item.updatedAt, data: data) {
                            Button {
                                onPreviewImage?(data)
                            } label: {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看物品照片")
                        }
                    }

                    Spacer()

                    // 3. 底部：持有成本与天数数据栏
                    HStack(alignment: .bottom) {
                        if costSummary.isTracked {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("日均持有成本")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text(String(format: "¥%.1f/天", costSummary.dailyCost))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(costSummary.isResold ? Color(red: 0.5, green: 0.9, blue: 0.6) : Color(red: 1.0, green: 0.75, blue: 0.35))
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(costSummary.isResold ? "持有天数" : "已持有")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text("\(costSummary.holdingDays) 天")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.85))
                                }

                                if let price = item.purchasePrice, price > 0 {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("买入价")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.6))
                                        Text(String(format: "¥%.0f", price))
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.85))
                                    }
                                }
                            }
                        } else {
                            Text("随手记录，翻箱不愁")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Spacer()

                        // 更新时间提示
                        Text(item.updatedAt, format: .dateTime.month().day())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(16)
            }
            .frame(height: 180)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }

            // MARK: - 展开态详情及操作栏
            if isExpanded {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color(.separator))
                        .padding(.horizontal, 8)

                    // 备注内容
                    if let notes = item.notes, !notes.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "note.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                    }

                    // 成本与关联后继投入详情
                    if costSummary.isTracked {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("累计总投入")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "¥%.1f", costSummary.totalCost))
                                    .font(.subheadline.bold())
                            }

                            if linkedExpenseTotal > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("后继维护/配件")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "+¥%.1f", linkedExpenseTotal))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.indigo)
                                }
                            }

                            if costSummary.isResold, let resale = item.resalePrice {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("转卖回血")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "¥%.1f", resale))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.green)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                    }

                    // 操作栏：分享、编辑、删除
                    HStack(spacing: 10) {
                        Button {
                            onShare?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text("分享位置")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(Color(.secondarySystemFill))
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            onEdit?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("编辑")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(Color.indigo.opacity(0.14))
                            )
                            .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            onDelete?()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                        .fill(Color(.systemRed).opacity(0.12))
                                )
                                .foregroundStyle(Color(.systemRed))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除物品")
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

