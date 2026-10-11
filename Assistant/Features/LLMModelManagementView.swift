import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Qwen2.5-1.5B 本地大模型管理与测试面板
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
            // MARK: - 1. 模型状态卡片
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(modelManager.isModelDownloaded ? Color.green.gradient : Color.purple.gradient)
                                .frame(width: 48, height: 48)
                            Image(systemName: "brain.head.profile")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Qwen2.5-1.5B-Instruct")
                                .font(.headline)
                            Text("阿里通义千问端侧大模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(modelManager.isModelDownloaded ? "文件已下载" : (modelManager.isDownloading ? "下载中" : "未下载"))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    modelManager.isModelDownloaded ? Color.green.opacity(0.15) :
                                    (modelManager.isDownloading ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.15))
                                )
                            )
                            .foregroundStyle(
                                modelManager.isModelDownloaded ? Color.green :
                                (modelManager.isDownloading ? Color.orange : Color.secondary)
                            )
                    }

                    Divider()

                    // 参数规格
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("模型参数").foregroundStyle(.secondary).font(.caption)
                            Text("15.4 亿 (1.54B)").font(.caption.bold())
                            Text("量化精度").foregroundStyle(.secondary).font(.caption)
                            Text("Q4_K_M (4-bit)").font(.caption.bold())
                        }
                        GridRow {
                            Text("文件体积").foregroundStyle(.secondary).font(.caption)
                            Text("约 986 MB").font(.caption.bold())
                            Text("运行内存").foregroundStyle(.secondary).font(.caption)
                            Text("约 980 MB").font(.caption.bold())
                        }
                        GridRow {
                            Text("推理引擎").foregroundStyle(.secondary).font(.caption)
                            Text("llama.cpp (Metal GPU)").font(.caption.bold()).foregroundStyle(.purple)
                            Text("引擎状态").foregroundStyle(.secondary).font(.caption)
                            Text(inferenceService.localEngineStatus)
                                .font(.caption.bold())
                                .foregroundStyle(inferenceService.isLocalModelLoaded ? .green : .secondary)
                                .lineLimit(1)
                        }
                        GridRow {
                            Text("存储位置").foregroundStyle(.secondary).font(.caption)
                            Text("沙盒 / Documents / Models").font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("模型基础信息")
            } footer: {
                Text("已接入 llama.cpp 端侧推理引擎（Apple Metal GPU 加速）。模型文件下载或导入后，所有对话问答均在 iPhone 本机离线完成，隐私数据不出设备。")
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
                            .tint(.purple)

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
                                    .foregroundStyle(.purple)
                                Spacer()
                                Button("释放显存") {
                                    Task {
                                        await inferenceService.unloadLocalModel()
                                        Haptic.light()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
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
                                .tint(.purple)
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    Picker("极速下载节点", selection: $modelManager.selectedSource) {
                        ForEach(LLMDownloadSource.allCases) { src in
                            Text(src.rawValue).tag(src)
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
                            .tint(.purple)

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
                                Text("一键极速下载 (~986 MB)")
                                    .bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从「文件」App 导入外部 GGUF 文件", systemImage: "folder.badge.plus")
                    }
                }

                if let err = modelManager.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("模型文件获取与管理")
            } footer: {
                Text("💡 提示：您也可以在 Mac 上下载好 `qwen2.5-1.5b-instruct-q4_k_m.gguf` 后，通过 AirDrop 发送至 iPhone「文件」App，或通过访达连线拖入本 App 的「Models」目录。")
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
                        .tint(.purple)
                        .disabled(isTesting || testPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
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
                                .foregroundStyle(.purple)

                            Text(inferenceService.currentOutput)
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
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
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - 4. 开发者联调模式 (可选局域网 Ollama)
            Section("局域网免下载联调 (可选)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("如果 Mac 电脑同一 Wi-Fi 下正在运行 `ollama run qwen2.5:1.5b`，填入 Mac 局域网 IP 即可免下载手机直接联调。")
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)))
                    Toggle("允许向此局域网端点发送待办、快递码、开销等生活数据", isOn: $inferenceService.remoteContextConsent)
                    Text("连接状态：\(inferenceService.remoteConnectionStatus)")
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

    @ViewBuilder
    private func samplePromptButton(_ prompt: String) -> some View {
        Button {
            testPrompt = prompt
            Haptic.light()
        } label: {
            Text(prompt)
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
