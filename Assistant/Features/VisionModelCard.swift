import AssistantCore
import SwiftUI

/// 「图像识别模型」分区：多部件包的逐件状态、顺序下载与整包删除。
///
/// 它刻意不是 Section 0 单选列表里的一行：视觉包必须两个文件同版本才可用，也不参与日常问答。
/// 混进单选会让「选中它去聊天」变成一条必然失败的路径，而删掉其中一半又会留下
/// 「看起来已就绪、实际加载失败」的包——所以这里只给「整包」级别的删除。
struct VisionModelCard: View {
    @StateObject private var manager = VisionModelManager.shared
    @State private var showDeleteConfirm = false
    @State private var showDiscardConfirm = false

    private var bundle: VisionModelBundle { manager.bundle }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(manager.parts, id: \.id) { part in
                    partRow(part)
                    if part.role == .languageModel { Divider() }
                }
                if manager.isDownloading || manager.hasAnyResumeData { progressBlock }
                if manager.availableSources.count > 1 { sourcePicker }
                actions
                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppColor.danger)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(L10n.tr("图像识别模型（拍照算热量专用）"))
        } footer: {
            Text(L10n.tr(bundle.usageNote) + "\n" + L10n.tr("语言模型与视觉编码器必须同版本，缺任一件都不能用；因此这里只提供整包删除。"))
        }
        .alert(L10n.tr("删除图像识别模型？"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("删除"), role: .destructive) { manager.deleteBundle() }
        } message: {
            Text(L10n.choose(
                "已下载的部件文件都会删除，释放约 \(manager.bytesOnDisk)。之后「拍照算热量」会退回系统图片识别。",
                "Downloaded part files will be deleted, freeing about \(manager.bytesOnDisk). Calorie-from-photo will fall back to Apple's image classifier."
            ))
        }
        .alert(L10n.tr("放弃下载进度？"), isPresented: $showDiscardConfirm) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("放弃"), role: .destructive) { manager.discardProgress() }
        } message: {
            Text(L10n.tr("已下载完成的部件文件会保留，只清掉断点进度；下次下载从零开始。"))
        }
    }

    // MARK: - 头部摘要

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(statusIconColor.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "camera.viewfinder")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr(bundle.shortName))
                    .font(.headline)
                Text(L10n.tr(bundle.subtitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(L10n.tr(statusText))
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.15)))
                    .foregroundStyle(statusColor)
                Text(manager.formattedBundleSize)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 逐件状态

    @ViewBuilder
    private func partRow(_ part: VisionModelPart) -> some View {
        let state = manager.state(for: part)
        HStack(spacing: 8) {
            Image(systemName: partIcon(part.role))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(part.displayName))
                    .font(.caption.bold())
                if let release = state.verifiedReleaseVersion {
                    Text(L10n.choose("已核验 \(release)", "Verified \(release)"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppColor.success)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(partReason(state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(manager.formattedSize(for: part))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Image(systemName: partSymbol(state))
                    .font(.caption)
                    .foregroundStyle(partColor(state))
            }
        }
    }

    private func partIcon(_ role: VisionModelPart.Role) -> String {
        role == .languageModel ? "cpu" : "eye"
    }

    private func partSymbol(_ state: VisionModelManager.PartState) -> String {
        switch state.validation {
        case .validated: return "checkmark.seal.fill"
        case .validating: return "hourglass"
        case .validationFailed: return "exclamationmark.triangle.fill"
        case .noModelFile: return state.hasResumeData ? "arrow.down.circle.dotted" : "circle.dashed"
        }
    }

    private func partColor(_ state: VisionModelManager.PartState) -> Color {
        switch state.validation {
        case .validated: return AppColor.success
        case .validating: return AppColor.warning
        case .validationFailed: return AppColor.danger
        case .noModelFile: return state.hasResumeData ? AppColor.feature : Color.secondary
        }
    }

    private func partReason(_ state: VisionModelManager.PartState) -> String {
        switch state.validation {
        case .validationFailed(let reason): return L10n.tr(reason)
        case .validating: return L10n.tr("校验中")
        case .noModelFile: return state.hasResumeData ? L10n.tr("已暂停，可续传") : L10n.tr("未下载")
        case .validated: return L10n.tr("已就绪")
        }
    }

    // MARK: - 进度

    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: manager.overallProgress)
                .tint(AppColor.feature)
            HStack {
                Text(L10n.choose(
                    "整包 \(ByteCountFormatter.string(fromByteCount: manager.overallDownloadedBytes, countStyle: .file)) / \(manager.formattedBundleSize)",
                    "Bundle \(ByteCountFormatter.string(fromByteCount: manager.overallDownloadedBytes, countStyle: .file)) of \(manager.formattedBundleSize)"
                ))
                    .font(.caption2.monospaced())
                Spacer()
                if manager.isDownloading {
                    Text(String(format: "%.1f MB/s", manager.downloadSpeedMBps))
                        .font(.caption2.monospaced())
                }
            }
            Text("\(Int(manager.overallProgress * 100))%")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 下载源

    @ViewBuilder
    private var sourcePicker: some View {
        Picker(L10n.tr("下载源"), selection: Binding(
            get: { manager.selectedSource },
            set: { manager.selectSource($0) }
        )) {
            ForEach(manager.availableSources, id: \.rawValue) { source in
                Text(sourceLabel(source)).tag(source)
            }
        }
        .pickerStyle(.segmented)
    }

    private func sourceLabel(_ source: ModelDownloadSourceID) -> String {
        switch source {
        case .modelScope: return "ModelScope"
        case .huggingFace: return "Hugging Face"
        }
    }

    // MARK: - 操作

    private var actions: some View {
        HStack(spacing: 10) {
            if manager.isDownloading {
                Button {
                    manager.pauseDownload()
                } label: {
                    actionLabel(L10n.tr("暂停"), "pause.circle.fill", AppColor.warning)
                }
            } else {
                Button {
                    manager.startDownload()
                } label: {
                    actionLabel(
                        manager.hasAnyResumeData ? L10n.tr("继续下载") : L10n.tr("下载全部"),
                        "arrow.down.circle.fill",
                        AppColor.feature
                    )
                }
                .disabled(manager.isBundleReady)
            }

            if manager.hasAnyResumeData {
                Button {
                    showDiscardConfirm = true
                } label: {
                    actionLabel(L10n.tr("放弃进度"), "minus.circle", .secondary)
                }
            }

            if manager.hasAnyPartOnDisk {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    actionLabel(L10n.tr("删除"), "trash", AppColor.danger)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.footnote)
            Text(title).font(.footnote.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }

    // MARK: - 状态

    /// 整包只在「两件都校验通过」时才算就绪；任何一件在校验中，整体就不能显示就绪。
    private var statusText: String {
        if manager.isDownloading { return L10n.tr("下载中") }
        if isChecking { return L10n.tr("校验中") }
        if manager.isBundleReady {
            return LlamaCppEngine.isEngineLinked ? L10n.tr("已就绪") : L10n.tr("引擎未链接")
        }
        if hasFailedPart { return L10n.tr("部件异常") }
        if manager.hasAnyPartOnDisk { return L10n.tr("不完整") }
        return L10n.tr("未下载")
    }

    private var statusColor: Color {
        if manager.isDownloading { return AppColor.warning }
        if manager.isBundleReady { return LlamaCppEngine.isEngineLinked ? AppColor.success : AppColor.danger }
        if isChecking { return AppColor.warning }
        if hasFailedPart { return AppColor.danger }
        return .secondary
    }

    private var isChecking: Bool {
        manager.parts.contains { manager.state(for: $0).validation == .validating }
    }

    private var hasFailedPart: Bool {
        manager.parts.contains { manager.state(for: $0).isValidationFailed }
    }

    private var statusIconColor: Color {
        manager.isBundleReady ? AppColor.success : AppColor.feature
    }
}
