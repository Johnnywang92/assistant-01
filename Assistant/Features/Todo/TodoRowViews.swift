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
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onEnterReorder: (() -> Void)? = nil
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
                    AppMotion.animate(.easeOut(duration: 0.45)) {
                        ringScale = 2.0
                        ringOpacity = 0.0
                    }
                    // 2. 延迟 0.45 秒平滑移入已完成列表
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.75)) {
                            item.markAsCompleted(in: context)
                            isAnimatingCompletion = false
                            ringScale = 0.5
                            ringOpacity = 0.0
                        }
                        try? context.save()
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
                    try? context.save()
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
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemFill)))

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
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? Color.orange.opacity(0.20) : .clear)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            if item.hasQRCodeOrTicket {
                Button("出示预约二维码 / 凭证", systemImage: "qrcode.viewfinder") {
                    onShowQRCode?()
                    Haptic.medium()
                }
            }

            // 一键把取件码/行程倒计时推上灵动岛，并自动同步到 Apple Watch 智能叠放
            if item.status == .active,
               item.type == .parcel || item.type == .returnParcel || item.type == .travelBooking || item.type == .event {
                Button("🏝️ 上灵动岛（同步手表）", systemImage: "platter.filled.top.iphone") {
                    let started: Bool
                    if item.type == .travelBooking || item.type == .event {
                        started = LiveActivityService.startTravelActivity(for: item)
                    } else {
                        started = LiveActivityService.startPickupActivity(for: [item])
                    }
                    if started { Haptic.success() } else { Haptic.warning() }
                }
            }

            if item.status == .active && WeChatCommunicationHelper.isWeChatCommunication(title: item.title, detail: item.detail) {
                let kind = WeChatCommunicationHelper.communicationKind(title: item.title, detail: item.detail)
                Button(kind.buttonTitle, systemImage: kind.iconName) {
                    if let url = URL(string: WeChatCommunicationHelper.weChatURLScheme) {
                        UIApplication.shared.open(url)
                        Haptic.light()
                    }
                }
            }

            Button("编辑事项", systemImage: "pencil") {
                onEdit?()
                Haptic.light()
            }

            Divider()

            Section("调整排序") {
                if let onMoveToTop {
                    Button("移至顶部 (置顶)", systemImage: "arrow.up.to.line") {
                        onMoveToTop()
                    }
                }
                if let onMoveUp {
                    Button("上移一位", systemImage: "arrow.up") {
                        onMoveUp()
                    }
                }
                if let onMoveDown {
                    Button("下移一位", systemImage: "arrow.down") {
                        onMoveDown()
                    }
                }
                if let onEnterReorder {
                    Button("进入拖拽排序模式", systemImage: "arrow.up.arrow.down") {
                        onEnterReorder()
                    }
                }
            }

            Divider()

            if let code = item.pickupCode {
                Button(item.type == .returnParcel ? "复制寄件码" : "复制取件码", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = code
                    Haptic.light()
                }
            }
            if let src = item.sourceText {
                Button("复制原文", systemImage: "text.quote") {
                    UIPasteboard.general.string = src
                    Haptic.light()
                }
            }
            Button("分享此待办卡片", systemImage: "square.and.arrow.up") {
                onShare?()
                Haptic.light()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onMoveToTop {
                Button {
                    onMoveToTop()
                } label: {
                    Label("置顶", systemImage: "arrow.up.to.line")
                }
                .tint(.orange)
            }

            if let onMoveUp {
                Button {
                    onMoveUp()
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .tint(.blue)
            }

            if let onMoveDown {
                Button {
                    onMoveDown()
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .tint(.indigo)
            }

            if let onEnterReorder {
                Button {
                    onEnterReorder()
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .tint(.teal)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Haptic.warning()
                item.cleanupExternalIntegrations()
                context.delete(item)
                try? context.save()
            } label: { Label("删除", systemImage: "trash") }
        }
        .themedRow()
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
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                        seniorManager.speakSenior(text: speechText, id: item.id.uuidString)
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
                    try? context.save()
                }
                .buttonStyle(.borderedProminent)
                Button("忽略", role: .destructive) {
                    context.delete(item)
                    try? context.save()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .themedRow()
    }
}
