import AssistantCore
import SwiftData
import SwiftUI

/// 心理记录导出面板。
///
/// ## 设计要点
///
/// 1. **隐私告知在显眼处**，不是在角落一行小字——
///    这份内容会离开本机，送到第三方模型服务。
/// 2. **App 绝不自动上传**：只生成文本，由用户自己用系统分享面板发送。
///    「数据出不出本机」由用户按那一下决定。
/// 3. **安全信号优先**：若记录里含自伤意念作答，面板顶部显著提示，
///    并把 12356 直接摆在最上面——用户此刻可能正需要它。
/// 4. **预览可见**：用户能先看到要发出去的内容，再决定发不发。
struct PsychExportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PsychScaleRecord.completedAt, order: .reverse)
    private var scaleRecords: [PsychScaleRecord]

    @Query(sort: \MoodCheckInRecord.day, order: .reverse)
    private var moodRecords: [MoodCheckInRecord]

    @State private var format: PsychExportFormat = .markdown
    @State private var showPreview = false
    /// 已复制到剪贴板（用于按钮反馈与 toast）。
    @State private var copied = false

    private var payload: PsychExportPayload {
        PsychDataAdapter.exportPayload(
            scaleRecords: scaleRecords,
            moodRecords: moodRecords,
            recentAverageSleepHours: recentAverageSleepHours,
            physiologicalStressScore: HealthKitService.shared.pleasureEvaluation?.stressScore
        )
    }

    private var exportText: String {
        PsychExportFormatter.format(payload, as: format)
    }

    /// 近 7 日平均睡眠。读不到返回 nil（不当 0）。
    ///
    /// 实现收敛在 `PsychDataAdapter`——主页/结果页/导出三处曾各写一份。
    private var recentAverageSleepHours: Double? {
        PsychDataAdapter.recentAverageSleepHours(context: context)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    privacyNotice
                    if payload.hasSafetySignal {
                        safetySignalNotice
                    }
                    formatPicker
                    contentSummary
                    previewSection
                    shareSection
                }
                .padding(AppSpacing.lg)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.tr("导出记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("关闭")) { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if copied {
                    Text(L10n.tr("✓ 已复制。切换到任意大模型粘贴即可"))
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 隐私告知

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label(L10n.tr("这份内容会离开本机"), systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.warning)
            Text(L10n.tr("导出的文字包含你的量表作答与每日记录。分享后它会进入你选择的第三方服务（可能是大模型），不再由本 App 控制。"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(AppColor.softFill(AppColor.warning))
        )
    }

    // MARK: - 安全信号

    private var safetySignalNotice: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label(L10n.tr("记录中含有自伤意念的作答"), systemImage: "lifepreserver.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.danger)
            Text(L10n.tr("导出内容会明确标注这一点，并要求接收它的模型优先给出求助路径。"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let phone = PsychHelpResources.nationalHotline.phoneNumber {
                Link(destination: URL(string: "tel://\(phone)")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "phone.fill")
                        Text("\(phone) \(L10n.tr("24 小时 · 免费 · 保密"))")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColor.danger)
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - 格式选择

    /// 格式显示名。
    ///
    /// `L10n.tr` 只能查**固定 key**，变量查表必然失败并回落成中文。
    /// 所以这里按 case 映射到固定 key，而不是直接用 `format.displayName`。
    private func formatDisplayName(_ format: PsychExportFormat) -> String {
        switch format {
        case .markdown: return L10n.tr("Markdown（可直接粘贴给模型）")
        case .json: return L10n.tr("JSON（给有 API 的场景）")
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.tr("格式"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
            Picker(L10n.tr("格式"), selection: $format) {
                ForEach(PsychExportFormat.allCases, id: \.self) { f in
                    Text(formatDisplayName(f)).tag(f)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 内容摘要

    private var contentSummary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.tr("将要导出的内容"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
            summaryRow(L10n.tr("量表记录"), "\(payload.scaleRecords.count) \(L10n.tr("次"))")
            summaryRow(L10n.tr("每日微记录"), "\(payload.moodEntries.count) \(L10n.tr("天"))")
            if payload.recentAverageSleepHours != nil {
                summaryRow(L10n.tr("睡眠均值"), "\(String(format: "%.1f", payload.recentAverageSleepHours ?? 0)) \(L10n.tr("小时"))")
            }
            if payload.physiologicalStressScore != nil {
                summaryRow(L10n.tr("压力指数"), "\(payload.physiologicalStressScore ?? 0) / 100")
            }
            Text(L10n.tr("不含：逐日心率与心率变异性原始数据、任何身份信息。导出内容自带给模型的说明，要求它不做医学诊断。"))
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xs)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppColor.text)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AppColor.secondaryText)
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            DisclosureGroup(isExpanded: $showPreview) {
                ScrollView(.horizontal) {
                    Text(exportText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppColor.text)
                        .textSelection(.enabled)
                        .padding(AppSpacing.sm)
                }
                .frame(maxHeight: 260)
                .background(AppColor.fillTertiary, in: RoundedRectangle(cornerRadius: AppRadius.chip))
                .padding(.top, AppSpacing.sm)
            } label: {
                Text(L10n.tr("预览内容"))
                    .font(.subheadline)
                    .foregroundStyle(AppColor.text)
            }
            .tint(AppColor.secondaryText)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 分享与复制

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // 「复制」是主按钮而不是分享——
            //
            // 分享面板里的目标 App 由系统列出，用户得先找到再选；
            // 而复制后直接切到任意大模型粘贴即可，**任何** App 都能用
            // （豆包、Kimi、DeepSeek、通义都不需要深链支持）。
            // 深链跳转在这些 App 上大多不可用（未公开 scheme 或未安装时静默失败），
            // 所以不作为主路径。
            Button {
                copyToClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(copied ? L10n.tr("已复制") : L10n.tr("复制内容"))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm)
                .background(copied ? AppColor.success : AppColor.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(payload.scaleRecords.isEmpty && payload.moodEntries.isEmpty)

            ShareLink(item: exportText) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text(L10n.tr("分享给其他模型"))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColor.info)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.softFill(AppColor.info), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(payload.scaleRecords.isEmpty && payload.moodEntries.isEmpty)

            Text(L10n.tr("复制后切换到任意大模型粘贴即可。内容里已经写明了这份数据的性质与解读要求。"))
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    /// 复制到剪贴板。
    ///
    /// 沿用 `PeriodicReportView.exportAndCopy()` 的既有模式：
    /// `UIPasteboard` + 触感反馈 + 定时清除 toast 状态。
    private func copyToClipboard() {
        UIPasteboard.general.string = exportText
        Haptic.success()
        withAnimation(.spring(duration: 0.25)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                copied = false
            }
        }
    }
}
