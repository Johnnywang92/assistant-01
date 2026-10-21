import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 本地大模型（Qwen3 / Qwen2.5）管理与测试面板
struct LLMModelManagementView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var modelManager = LLMModelManager.shared
    @StateObject private var inferenceService = LLMInferenceService.shared

    @State private var showFileImporter = false
    @State private var testPrompt: String = "我今天有哪些待取快递？"
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        List {
            // MARK: - 0. 模型规格切换（支持更换更强大的 Qwen3 模型）
            Section {
                ForEach(LLMModelPreset.allCases) { preset in
                    let isSelected = modelManager.selectedPreset == preset
                    let isInstalled = modelManager.hasModelFileOnDisk(for: preset)
                    Button {
                        guard modelManager.selectedPreset != preset else { return }
                        modelManager.selectedPreset = preset
                        Haptic.light()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? AppColor.feature : .secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(L10n.tr(preset.displayName))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    if isInstalled {
                                        Text(L10n.tr("已下载"))
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(AppColor.success.opacity(0.15)))
                                            .foregroundStyle(AppColor.success)
                                    }
                                }
                                Text(preset.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(preset.formattedExpectedSize)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("切换端侧模型规格 (支持 Qwen3)")
            } footer: {
                Text("推荐使用新一代 Qwen3-1.7B（速度与推理能力均衡）或更强大的 Qwen3-4B（复杂拆解与食物热量推算更准）。已下载的模型在切换时不会丢失，可随时自由切换。")
            }

            // MARK: - 1. 模型状态卡片
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                .fill(badgeIconColor.gradient)
                                .frame(width: 48, height: 48)
                            Image(systemName: "brain.head.profile")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(modelManager.selectedPreset.shortName)
                                .font(.headline)
                            Text("阿里通义千问端侧大模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(L10n.tr(badgeText))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(badgeColor.opacity(0.15))
                            )
                            .foregroundStyle(badgeColor)
                    }

                    Divider()

                    // 参数规格
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("模型参数").foregroundStyle(.secondary).font(.caption)
                            Text(modelManager.selectedPreset.parameterCountText).font(.caption.bold())
                            Text("量化精度").foregroundStyle(.secondary).font(.caption)
                            Text("Q4_K_M (4-bit)").font(.caption.bold())
                        }
                        GridRow {
                            Text("文件体积").foregroundStyle(.secondary).font(.caption)
                            Text(modelManager.selectedPreset.formattedExpectedSize).font(.caption.bold())
                            Text("运行内存").foregroundStyle(.secondary).font(.caption)
                            Text(modelManager.selectedPreset.estimatedRAMText).font(.caption.bold())
                        }
                        GridRow {
                            Text("推理引擎").foregroundStyle(.secondary).font(.caption)
                            Text(isEngineLinked ? "llama.cpp (Metal GPU)" : "未链接")
                                .font(.caption.bold())
                                .foregroundStyle(isEngineLinked ? AppColor.feature : AppColor.warning)
                            Text("引擎状态").foregroundStyle(.secondary).font(.caption)
                            Text(inferenceService.localEngineStatus)
                                .font(.caption.bold())
                                .foregroundStyle(inferenceService.isLocalModelLoaded ? .green : .secondary)
                                .lineLimit(1)
                        }
                        GridRow {
                            Text("存储位置").foregroundStyle(.secondary).font(.caption)
                            Text("Models/\(modelManager.selectedPreset.fileName)").font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)

                // 能力边界如实告知：二进制未链接时，「已就绪」是虚假承诺
                if !isEngineLinked {
                    Label {
                        Text(LlamaCppEngine.engineLinkHint)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColor.warning)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("模型基础信息")
            } footer: {
                if isEngineLinked {
                    Text("已接入 llama.cpp 端侧推理引擎（Apple Metal GPU 加速）。模型文件下载或导入后，所有对话问答均在 iPhone 本机离线完成，隐私数据不出设备。")
                } else {
                    Text("当前构建未包含端侧推理二进制，下载的模型文件不会被用于回答。问答由本机规则引擎应答，同样不联网；如需真实模型推理，请在真机上运行。")
                }
            }

            // MARK: - 2. 下载与文件获取控制
            Section {
                if modelManager.isDownloading {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("下载进度：\(Int(modelManager.downloadProgress * 100))%")
                                .font(.subheadline.bold())
                            Spacer()
                            if modelManager.downloadSpeedMBps > 0 {
                                Text(String(format: "%.1f MB/s", modelManager.downloadSpeedMBps))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tint)
                            }
                        }

                        ProgressView(value: modelManager.downloadProgress)
                            .tint(AppColor.feature)

                        HStack {
                            let downloadedMB = Double(modelManager.downloadedBytes) / 1024.0 / 1024.0
                            let totalMB = Double(modelManager.totalBytes) / 1024.0 / 1024.0
                            Text(String(format: "%.1f MB / %.1f MB", downloadedMB, totalMB))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("暂停") {
                                modelManager.pauseDownload()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("取消", role: .destructive) {
                                modelManager.discardProgressAndReset()
                            }
                            .font(.caption.bold())
                        }
                    }
                    .padding(.vertical, 4)
                } else if modelManager.validationStatus == .validating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在校验模型完整性…")
                                .font(.subheadline)
                            Text("首次校验大文件约需数十秒，校验通过前模型不可用。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("删除", role: .destructive) {
                            modelManager.deleteModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else if case .validationFailed(let reason) = modelManager.validationStatus {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("模型文件校验未通过", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColor.danger)
                            .font(.subheadline)
                        Text(L10n.tr(reason))
                            .font(.caption)
                            .foregroundStyle(AppColor.danger)
                        HStack(spacing: 10) {
                            Button("重新校验") {
                                modelManager.checkModelStatus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("重新导入") {
                                showFileImporter = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppColor.feature)
                            .controlSize(.small)
                            Button("删除", role: .destructive) {
                                modelManager.deleteModel()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                } else if modelManager.isModelDownloaded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("模型文件已安装 (\(modelManager.formattedModelSize))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                            Spacer()
                            Button("删除", role: .destructive) {
                                modelManager.deleteModel()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        HStack(spacing: 10) {
                            if inferenceService.isLocalModelLoaded {
                                Label("Metal 显存已就绪", systemImage: "bolt.horizontal.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(AppColor.feature)
                                Spacer()
                                Button("释放显存") {
                                    Task {
                                        await inferenceService.unloadLocalModel()
                                        Haptic.light()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else if isEngineLinked {
                                Label("首次问答将自动映射加载至 Metal", systemImage: "cpu")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("立即预加载") {
                                    Task {
                                        await inferenceService.preloadLocalModel()
                                        Haptic.success()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppColor.feature)
                                .controlSize(.small)
                            } else {
                                // 未链接二进制时隐藏「预加载」入口：点击必然失败
                                Label("当前构建不含端侧推理能力", systemImage: "cpu")
                                    .font(.caption)
                                    .foregroundStyle(AppColor.warning)
                                Spacer()
                            }
                        }
                    }
                } else {
                    Picker("极速下载节点", selection: $modelManager.selectedSource) {
                        ForEach(LLMDownloadSource.allCases) { src in
                            Text(L10n.tr(src.rawValue)).tag(src)
                        }
                    }
                    .pickerStyle(.menu)

                    if modelManager.hasResumeData {
                        VStack(spacing: 8) {
                            Button {
                                modelManager.startDownload()
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                    Text("继续断点下载")
                                        .bold()
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppColor.feature)

                            HStack {
                                Text("已保存中断前进度，无需从头下载")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("放弃并重来", role: .destructive) {
                                    modelManager.discardProgressAndReset()
                                }
                                .font(.caption2)
                            }
                        }
                    } else {
                        Button {
                            modelManager.startDownload()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                Text("一键极速下载 \(modelManager.selectedPreset.shortName) (\(modelManager.selectedPreset.formattedExpectedSize))")
                                    .bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.feature)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从「文件」App 导入外部 GGUF 文件", systemImage: "folder.badge.plus")
                    }
                }

                if let err = modelManager.errorMessage {
                    Text(L10n.tr(err))
                        .font(.caption)
                        .foregroundStyle(AppColor.danger)
                }
            } header: {
                Text("模型文件获取与管理")
            } footer: {
                Text("💡 提示：您也可以在 Mac 上下载好 `\(modelManager.selectedPreset.fileName)`（或任意 Qwen3 / Qwen2.5 GGUF 模型）后，通过 AirDrop 发送至 iPhone「文件」App 导入。")
            }

            // MARK: - 3. 本地推理与问答沙盒测试
            Section("llama.cpp 端侧推理沙盒测试") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("测试提示词（将自动附带待办/快递/记账真实上下文）：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("输入你想问助理的问题...", text: $testPrompt)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            runTestInference()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .padding(.horizontal, 8)
                            } else {
                                Text("测试")
                                    .bold()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.feature)
                        .disabled(isTesting || testPrompt.trimmingCharacters(in: .whitespaces).isEmpty || !isAnyInferenceEntryAvailable)

                    if !isAnyInferenceEntryAvailable {
                        Text(isEngineLinked
                             ? "端侧模型需完整性校验通过（或已配置局域网端点）后方可测试。"
                             : "当前构建未链接推理二进制，本地测试不可用；可改用下方局域网端点联调。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    }

                    // 快速样例问题标签
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            samplePromptButton("今天有什么待取快递？")
                            samplePromptButton("今天花了多少钱？")
                            samplePromptButton("最近有什么重要纪念日？")
                            samplePromptButton("提醒我明天下午3点买咖啡")
                        }
                    }

                    if isTesting && !inferenceService.currentOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("端侧实时流式输出：")
                                .font(.caption.bold())
                                .foregroundStyle(AppColor.feature)

                            Text(inferenceService.currentOutput)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(AppColor.surface))
                        }
                        .padding(.top, 4)
                    } else if let result = testResult {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("问答结果：")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            Text(result)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(AppColor.surface))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - 4. 开发者联调模式 (可选局域网 Ollama)
            Section("局域网免下载联调 (可选)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("如果 Mac 电脑同一 Wi-Fi 下正在运行 `ollama run \(inferenceService.effectiveOllamaModel)`（支持 `qwen3:4b`、`qwen3:8b`、`qwen3:1.7b` 等更强大的模型），填入 Mac 局域网 IP 即可免下载手机直接联调。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        TextField("例如：http://192.168.1.8:11434", text: $inferenceService.developerEndpoint)
                            .textFieldStyle(.plain)
                            .font(.caption.monospaced())
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(AppColor.surface))

                    HStack {
                        Image(systemName: "cube.box")
                            .foregroundStyle(.secondary)
                        TextField("远端模型名（留空默认 \(modelManager.selectedPreset.ollamaModelTag)）", text: $inferenceService.remoteOllamaModel)
                            .textFieldStyle(.plain)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(AppColor.surface))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(["qwen3:1.7b", "qwen3:4b", "qwen3:8b", "qwen2.5:1.5b"], id: \.self) { tag in
                                Button(tag) {
                                    inferenceService.remoteOllamaModel = tag
                                    Haptic.light()
                                }
                                .font(.caption2.monospaced())
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }

                    Toggle("允许向此局域网端点发送待办、快递码、开销等生活数据", isOn: $inferenceService.remoteContextConsent)
                    Text("连接状态：\(inferenceService.remoteConnectionStatus)（当前远端模型：\(inferenceService.effectiveOllamaModel)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AI 本地大模型")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
    }

    // MARK: - 辅助操作

    /// 编译期是否真的链接了推理二进制。未链接时全页不得出现「已就绪」类表述。
    private var isEngineLinked: Bool { LlamaCppEngine.isEngineLinked }

    /// 仅「校验通过」视为就绪；SHA-256 结论前不显示绿色徽标，避免状态误报
    private var badgeText: String {
        if modelManager.isDownloading { return "下载中" }
        switch modelManager.validationStatus {
        case .validated: return "校验通过"
        case .validating: return "校验中"
        case .validationFailed: return "校验失败"
        case .noModelFile: return "未下载"
        }
    }

    private var badgeColor: Color {
        if modelManager.isDownloading { return AppColor.warning }
        switch modelManager.validationStatus {
        case .validated: return AppColor.success
        case .validating: return AppColor.warning
        case .validationFailed: return AppColor.danger
        case .noModelFile: return .secondary
        }
    }

    private var badgeIconColor: Color {
        if modelManager.isDownloading { return AppColor.feature }
        switch modelManager.validationStatus {
        case .validated: return AppColor.success
        case .validating: return AppColor.warning
        case .validationFailed: return AppColor.danger
        case .noModelFile: return AppColor.feature
        }
    }

    private var isAnyInferenceEntryAvailable: Bool {
        let remoteConfigured = inferenceService.remoteContextConsent
            && !inferenceService.developerEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
        // 本地路径要求二进制确实已链接，否则点击必然抛 frameworkNotLinked
        return (isEngineLinked && modelManager.isModelDownloaded) || remoteConfigured
    }

    @ViewBuilder
    private func samplePromptButton(_ prompt: String) -> some View {
        Button {
            testPrompt = prompt
            Haptic.light()
        } label: {
            Text(L10n.tr(prompt))
                .font(.caption2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func runTestInference() {
        guard !testPrompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isTesting = true
        testResult = nil
        Haptic.light()

        Task {
            let reply = await inferenceService.generate(query: testPrompt, context: context)
            testResult = reply
            isTesting = false
            Haptic.success()
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try modelManager.importModel(from: url)
        } catch {
            modelManager.errorMessage = "导入文件失败：\(error.localizedDescription)"
        }
    }
}
