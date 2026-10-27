import AssistantCore
import SwiftUI

// MARK: - 排序调整模式顶栏提示胶囊

struct TodoReorderingBanner: View {
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.tint)

            Text("滑动排序中：按住右侧三条杠 ≡ 即可上下拖动")
                .font(.caption.bold())
                .foregroundStyle(.primary)

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("完成")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 长辈关怀模式顶栏胶囊

struct TodoSeniorModeBanner: View {
    let fontScaleTitle: String
    let onAdjust: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk.motion")
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.warning)

            Text("长辈关怀大字模式")
                .font(.caption.bold())
                .foregroundStyle(AppColor.warning)

            Text("(\(fontScaleTitle))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                onAdjust()
            } label: {
                HStack(spacing: 4) {
                    Text("调整字号")
                    Image(systemName: "textformat.size")
                }
                .font(.caption2.bold())
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppColor.softFill(AppColor.warning, opacity: 0.18)))
                .foregroundStyle(AppColor.warning)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppColor.softFill(AppColor.warning, opacity: 0.08))
    }
}

// MARK: - 气象预警轻量胶囊卡片

struct TodoWeatherAlertBanner: View {
    let banner: WeatherAlertService.AlertBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.icon)
                .font(.subheadline.bold())
                .foregroundStyle(banner.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(banner.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(banner.color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(banner.color.opacity(0.32), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
}

// MARK: - 临近纪念日筹备卡片

struct TodoAnniversaryPrepBanner: View {
    let upcoming: UpcomingAnniversaryInfo
    let onDismiss: () -> Void
    let onAddTodos: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("临近纪念日筹备")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text(upcoming.daysUntil == 0 ? "就在今天!" : "还有 \(upcoming.daysUntil) 天")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.pink.opacity(0.18)))
                                .foregroundStyle(.pink)
                        }

                        Text("「\(upcoming.title)」即将到来，提前备好惊喜让浪漫不留遗憾。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                        Text("不再提醒")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Label("💐 备鲜花", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.pink.opacity(0.08)))
                    .foregroundStyle(.pink)

                Label("🎂 订蛋糕", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
                    .foregroundStyle(.orange)

                Label("🍽️ 订餐厅", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
                    .foregroundStyle(.purple)

                Spacer()
            }

            Button {
                onAddTodos()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("一键将鲜花/蛋糕/餐厅加入待办")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color.pink, Color(red: 0.95, green: 0.35, blue: 0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.pink.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 节假日与出差旅行出行前购票备忘卡片

struct TodoTravelTicketPrepBanner: View {
    let info: UpcomingTravelTicketInfo
    let onDismiss: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "ticket.fill")
                        .font(.title3)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(info.title + (info.isHoliday ? "出行购票提醒" : "购票提醒"))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text(info.stageBadgeText)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo.opacity(0.18)))
                                .foregroundStyle(.indigo)
                        }

                        Text("出行日期 \(info.departureFormatted) · \(info.recommendationDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                        Text("不再提醒")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Label("🚄 火车票起售：\(info.trainSaleFormatted) (提前15天)", systemImage: "train.side.front.car")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
                        .foregroundStyle(.blue)

                    Label("🏛️ 场馆景区预约：\(info.scenicBookingFormatted) (提前7天)", systemImage: "building.columns.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
                        .foregroundStyle(.purple)

                    Label("✈️ 机票黄金预订：提前15-30天", systemImage: "airplane")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.08)))
                        .foregroundStyle(.teal)
                }
            }

            if let guide = info.destinationGuide {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text(guide)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 4)
            }

            Button {
                onConfirm()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.badge.questionmark.fill")
                    Text("查看并确认新增待办 (3项推荐)")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color.indigo, Color.blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.indigo.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
