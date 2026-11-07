import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

struct TodoRow: View {
    @Environment(\.modelContext) private var context
    let item: TodoItem
    var isHighlighted: Bool = false
    var onMoveToTop: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onShowQRCode: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @State private var isCopied: Bool = false
    @State private var isAnimatingCompletion: Bool = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.0

    private var isEffectivelyDone: Bool {
        item.status == .done || isAnimatingCompletion
    }

    private var typeColor: Color {
        switch item.type {
        case .parcel: return .orange
        case .returnParcel: return .indigo
        case .general, .event: return .blue
        case .work: return .brown
        case .medication: return .green
        case .housework: return .purple
        case .charging: return .yellow
        case .subscription, .bill: return .indigo
        case .itemExpiry: return .red
        case .anniversary: return .pink
        case .passwordSecurity: return .teal
        case .vehicleCare: return .indigo
        case .exercise: return .green
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .pink
        case .pet: return .orange
        case .other: return .secondary
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if item.status == .active {
                    // 1. 播放成功震动与波纹动效
                    Haptic.success()
                    isAnimatingCompletion = true
                    ringScale = 0.6
                    ringOpacity = 1.0
                    AppMotion.animate(.easeOut(duration: 0.65)) {
                        ringScale = 2.0
                        ringOpacity = 0.0
                    }
                    // 2. 延迟 0.70 秒（保留清晰的完成反馈体验，随后平滑移入已完成列表）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
                        AppMotion.animate(.spring(response: 0.38, dampingFraction: 0.78)) {
                            item.markAsCompleted(in: context)
                            isAnimatingCompletion = false
                            ringScale = 0.5
                            ringOpacity = 0.0
                        }
                        // 完成待办是唯一事实源：落库失败时 rollback 会把状态退回未完成，
                        // 必须让用户知道（否则重启后「已完成」又变回待办）。
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "完成待办") }) else {
                            Haptic.error()
                            return
                        }
                        // 同步桌面/锁屏组件快照（含技能练习的「今日已打卡」状态）
                        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
                    }
                } else {
                    // 反选/恢复为未完成
                    Haptic.medium()
                    AppMotion.animate(.spring(response: 0.3, dampingFraction: 0.75)) {
                        item.status = .active
                        TodoNotificationManager.shared.scheduleNotification(for: item)
                        isAnimatingCompletion = false
                    }
                    LifeEventTodoLink.syncTask(for: item, in: context)
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "恢复待办") }
                }
            } label: {
                ZStack {
                    // 绿色波纹动效光环
                    Circle()
                        .stroke(AppColor.success, lineWidth: 2)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                        .frame(width: seniorManager.isSeniorModeEnabled ? 34 : 24, height: seniorManager.isSeniorModeEnabled ? 34 : 24)

                    Image(systemName: isEffectivelyDone ? "checkmark.circle.fill" : "circle")
                        .font(seniorManager.isSeniorModeEnabled ? .title : .title2)
                        .foregroundStyle(isEffectivelyDone ? AppColor.success : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.65) : Color.secondary))
                        .scaleEffect(isAnimatingCompletion ? 1.25 : 1.0)
                        .responsiveAnimation(.spring(response: 0.28, dampingFraction: 0.5), value: isAnimatingCompletion)
                }
                .frame(width: seniorManager.isSeniorModeEnabled ? 44 : 28, height: seniorManager.isSeniorModeEnabled ? 44 : 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // VoiceOver：完成/取消完成待办的核心交互必须有可播报的状态与操作
            .accessibilityLabel(item.title)
            .accessibilityValue(isEffectivelyDone ? "已完成" : "未完成")
            .accessibilityHint(isEffectivelyDone ? "双击标记回未完成" : "双击完成该待办")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                if item.type == .parcel, let code = item.pickupCode {
                    HStack(spacing: 8) {
                        Text(code)
                            .font((seniorManager.isSeniorModeEnabled ? Font.title2 : Font.title3).monospaced().bold())
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                            .strikethrough(isEffectivelyDone)
                            .padding(.horizontal, seniorManager.isSeniorModeEnabled ? 10 : 8)
                            .padding(.vertical, seniorManager.isSeniorModeEnabled ? 5 : 3)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                    .fill(isEffectivelyDone ? Color.secondary.opacity(0.12) : AppColor.softFill(AppColor.warning, opacity: 0.15))
                            )

                        Button {
                            UIPasteboard.general.string = code
                            Haptic.light()
                            AppMotion.animate(.spring(duration: 0.2)) {
                                isCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                AppMotion.animate { isCopied = false }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制" : "复制")
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(isCopied ? AppColor.success : AppColor.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isCopied ? AppColor.softFill(AppColor.success, opacity: 0.15) : AppColor.softFill(AppColor.warning, opacity: 0.12))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制取件码")
                        .accessibilityHint("将取件码复制到剪贴板，便于在驿站时报出")
                    }

                    let placeText: String? = {
                        if let loc = item.location, let st = item.station, !loc.contains(st) {
                            return "\(st) · \(loc)"
                        }
                        return item.location ?? item.station
                    }()
                    if let text = [item.courier, placeText].compactMap({ $0 }).joined(separator: " · ") as String?, !text.isEmpty {
                        Text(L10n.tr(text))
                            .font(.subheadline)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                    }
                } else if item.type == .returnParcel {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                .fill(Color.indigo.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: seniorManager.isSeniorModeEnabled ? 28 : 24, height: seniorManager.isSeniorModeEnabled ? 28 : 24)
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.indigo)
                        }

                        Text(L10n.tr(item.title))
                            .font(.body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .medium)))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)

                        // 智能退货截止倒数预警胶囊
                        if let due = item.dueAt, !isEffectivelyDone {
                            let daysRemaining = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: due)).day ?? 0
                            HStack(spacing: 3) {
                                Image(systemName: daysRemaining <= 1 ? "exclamationmark.triangle.fill" : "clock.fill")
                                    .imageScale(.small)
                                Text(daysRemaining < 0 ? "已逾期" : (daysRemaining == 0 ? "今天截止!" : (daysRemaining == 1 ? "仅剩1天" : "退货剩\(daysRemaining)天")))
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    daysRemaining <= 0 ? AppColor.softFill(AppColor.danger, opacity: 0.18) :
                                    (daysRemaining <= 1 ? AppColor.softFill(AppColor.warning, opacity: 0.2) : Color.indigo.opacity(0.15))
                                )
                            )
                            .foregroundStyle(
                                daysRemaining <= 0 ? AppColor.danger :
                                (daysRemaining <= 1 ? AppColor.warning : Color.indigo)
                            )
                        }
                    }

                    if let code = item.pickupCode, !code.isEmpty {
                        HStack(spacing: 6) {
                            Text("寄件码: \(code)")
                                .font((seniorManager.isSeniorModeEnabled ? Font.subheadline : Font.caption).monospaced().bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: AppRadius.badge).fill(Color(.secondarySystemFill)))

                            Button {
                                UIPasteboard.general.string = code
                                Haptic.light()
                                AppMotion.animate(.spring(duration: 0.2)) { isCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    AppMotion.animate { isCopied = false }
                                }
                            } label: {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(isCopied ? AppColor.success : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("复制寄件码")
                            .accessibilityHint("将寄件码复制到剪贴板")
                        }
                    }

                    let stationOrCourier = [item.station, item.courier].compactMap({ $0 }).joined(separator: " · ")
                    if !stationOrCourier.isEmpty {
                        Text(stationOrCourier)
                            .font(.caption)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                    }

                    if let detail = item.displayConciseDetail, !detail.isEmpty {
                        Text(L10n.tr(detail))
                            .font(.footnote)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                .fill(typeColor.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: seniorManager.isSeniorModeEnabled ? 28 : 24, height: seniorManager.isSeniorModeEnabled ? 28 : 24)
                            Image(systemName: item.type.icon)
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : typeColor)
                        }
                        .padding(.top, 1)

                        Text(item.displayConciseTitle)
                            .font(.body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .semibold)))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 6)

                        rowTrailingButtons
                    }

                    if let locText = item.displayLocationText, !locText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.85))
                            Text(locText)
                                .font(.caption)
                                .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                MapNavigationService.openDirections(to: locText)
                            } label: {
                                Label("导航", systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let detail = item.displayConciseDetail, !detail.isEmpty {
                        Text(L10n.tr(detail))
                            .font(.footnote)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .lineLimit(2)
                            .lineSpacing(3)
                    }

                    if !isEffectivelyDone && WeChatCommunicationHelper.isWeChatCommunication(title: item.title, detail: item.detail) {
                        let kind = WeChatCommunicationHelper.communicationKind(title: item.title, detail: item.detail)
                        Button {
                            if let url = URL(string: WeChatCommunicationHelper.weChatURLScheme) {
                                UIApplication.shared.open(url)
                                Haptic.light()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: kind.iconName)
                                Text(kind.buttonTitle)
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule().fill(Color.green.opacity(0.12))
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.green.opacity(0.3), lineWidth: 0.8)
                            )
                            .foregroundStyle(Color.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(kind.buttonTitle)
                        .accessibilityHint("直接拉起微信应用")
                    }
                }

                HStack(spacing: 8) {
                    if let due = item.dueAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(due.formatted(date: .numeric, time: .shortened))
                        }
                        .font(.caption2)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(due < .now && !isEffectivelyDone ? Color.red : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.7) : Color.secondary))
                    } else {
                        Text(item.createdAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(seniorManager.isHighContrastEnabled ? 0.65 : 0.4))
                    }

                    if item.isRecurring {
                        HStack(spacing: 3) {
                            Image(systemName: "repeat")
                            Text(item.recurrenceSummaryText)
                        }
                        .font(.caption2.bold())
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isEffectivelyDone ? Color.secondary.opacity(0.12) : Color.blue.opacity(0.12))
                        )
                    }

                    if !item.tags.isEmpty {
                        ForEach(item.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2.bold())
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo.opacity(0.12)))
                                .foregroundStyle(Color.indigo)
                        }
                    }

                    Spacer(minLength: 0)

                    if item.type == .parcel || item.type == .returnParcel {
                        rowTrailingButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit?()
                Haptic.light()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(isHighlighted ? Color.orange.opacity(0.20) : .clear)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .stroke(Color.orange.opacity(0.75), lineWidth: 2)
                    }
                }
        )
        .responsiveAnimation(.easeInOut(duration: 0.25), value: isHighlighted)
        .id(item.id)
        .opacity(isEffectivelyDone ? 0.6 : 1.0)
        .responsiveAnimation(.easeInOut(duration: 0.25), value: isEffectivelyDone)
        .responsiveAnimation(.easeInOut(duration: 0.2), value: item.status)
        .padding(.vertical, 5)
        .contextMenu {
            // 手势层只保留「分享」：编辑走点按行，置顶走左侧滑，其余能力
            // 统一收进编辑页的「快捷动作」区，避免同一能力散落在三处入口。
            Button("分享此待办卡片", systemImage: "square.and.arrow.up") {
                onShare?()
                Haptic.light()
            }
        } preview: {
            sharePreview
        }
        // 单按钮且非破坏性，放开整滑：手一划到底即可置顶，不必瞄准 72pt 按钮。
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let onMoveToTop {
                Button {
                    onMoveToTop()
                } label: {
                    Label("置顶", systemImage: "arrow.up.to.line")
                }
                .tint(.orange)
            }
        }
        // 删除不可整滑直达：默认 allowsFullSwipe 为 true，一划到底会直接落库且无撤销。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptic.warning()
                item.cleanupExternalIntegrations()
                context.delete(item)
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "删除待办") }
            } label: { Label("删除", systemImage: "trash") }
        }
        .themedRow()
    }

    /// 长按预览只展示卡片内容，不放可点操作：菜单里唯一的动作就是分享。
    private var sharePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.type == .parcel || item.type == .returnParcel,
               let code = item.pickupCode, !code.isEmpty {
                Text(code)
                    .font(.title3.monospaced().bold())
                Text(item.displayConciseTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(item.displayConciseTitle)
                    .font(.headline)
                    .lineLimit(2)
            }

            if let place = item.location ?? item.station, !place.isEmpty {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let due = item.dueAt {
                Text(due, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private var rowTrailingButtons: some View {
        HStack(spacing: 6) {
            if item.hasQRCodeOrTicket {
                Button {
                    onShowQRCode?()
                    Haptic.medium()
                } label: {
                    Image(systemName: item.hasQRCode ? "qrcode" : "photo")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: seniorManager.isSeniorModeEnabled ? 38 : 30, height: seniorManager.isSeniorModeEnabled ? 38 : 30)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快速调出预约二维码")
            }

            if seniorManager.isVoiceBroadcastEnabled {
                Button {
                    let speechText: String = {
                        if item.type == .parcel, let code = item.pickupCode {
                            let station = item.location ?? item.station ?? ""
                            return "快递取件码：\(code)，\(item.displayConciseTitle)。\(station)"
                        } else if item.type == .returnParcel {
                            let codeStr = item.pickupCode.map { "，寄件码：\($0)" } ?? ""
                            return "退货待办：\(item.displayConciseTitle)\(codeStr)。\(item.displayConciseDetail ?? "")"
                        } else {
                            let detail = item.displayConciseDetail ?? ""
                            return "\(item.displayConciseTitle)。\(detail)"
                        }
                    }()

                    if seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString {
                        seniorManager.stopSpeaking()
                    } else {
                        Task { await seniorManager.speakSenior(text: speechText, id: item.id.uuidString) }
                        Haptic.light()
                    }
                } label: {
                    let isCurrentSpeaking = seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString
                    Image(systemName: isCurrentSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .caption)
                        .foregroundStyle(isCurrentSpeaking ? Color.orange : (seniorManager.isSeniorModeEnabled ? Color.orange : Color.secondary.opacity(0.7)))
                        .frame(width: seniorManager.isSeniorModeEnabled ? 38 : 26, height: seniorManager.isSeniorModeEnabled ? 38 : 26)
                        .background(
                            Circle()
                                .fill(isCurrentSpeaking ? Color.orange.opacity(0.2) : (seniorManager.isSeniorModeEnabled ? Color.orange.opacity(0.12) : Color.clear))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
    }
}

struct ReviewRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: TodoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("标题", text: $item.title, axis: .vertical)
                .font(.body)
            if let src = item.sourceText, src != item.title {
                Text(src).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Button("加入待办") {
                    item.status = .active
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "加入待办") }
                }
                .buttonStyle(.borderedProminent)
                Button("忽略", role: .destructive) {
                    context.delete(item)
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "忽略待办") }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .themedRow()
    }
}
