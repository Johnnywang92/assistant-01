import AssistantCore
import SwiftData
import SwiftUI

// MARK: - 判别层阈值校准调试页
//
// 数据源是投喂口确认卡攒下的 `OmniboxJudgmentFeedback`（topProbability/margin 快照
// + 点赞/点踩结论），校准计算在 AssistantCore `IntentThresholdCalibrator`（纯逻辑、有测试）。
// 本页只做展示 / 一键应用 / 导出，不做任何计算——计算进 Core 才能被 swift test 覆盖。

struct IntentThresholdCalibrationView: View {
    @Environment(\.modelContext) private var context

    @State private var report: IntentThresholdCalibrator.Report?
    @State private var quality: RecognitionQualityReport?
    @State private var samples: [JudgmentFeedback] = []
    @State private var override: (minTop: Double, minMargin: Double)? = AppSettings.intentThresholdOverride
    @State private var showAppliedToast = false

    var body: some View {
        List {
            statusSection
            qualitySection
            corpusSection
            recommendationSection
            candidateSection
            dataSection
        }
        .navigationTitle("判别阈值校准")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    // MARK: 当前状态

    private var statusSection: some View {
        Section {
            LabeledContent("生效阈值 · top1 概率下限") {
                Text(String(format: "%.2f", AppSettings.intentDecisionPolicy.minTopProbability))
                    .monospacedDigit()
            }
            LabeledContent("生效阈值 · 与次选最小差") {
                Text(String(format: "%.2f", AppSettings.intentDecisionPolicy.minMargin))
                    .monospacedDigit()
            }
            if let override {
                LabeledContent("来源") {
                    Text("校准覆盖（\(String(format: "%.2f", override.minTop)) / \(String(format: "%.2f", override.minMargin)))")
                        .foregroundStyle(.orange)
                }
                Button("恢复内置经验值 0.55 / 0.20", role: .destructive) {
                    AppSettings.intentThresholdOverride = nil
                    self.override = nil
                    reload()
                }
            } else {
                LabeledContent("来源") {
                    Text("内置经验值").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("当前生效")
        } footer: {
            Text("阈值同时约束两个条件：top1 概率够高、且与次选差距够大。任一不满足则不自动抽取，改为请用户确认。")
        }
    }

    // MARK: 识别质量（缺口 7 质检出口）

    private var qualitySection: some View {
        Section {
            LabeledContent("命中率") {
                if let accuracy = quality?.accuracy {
                    Text("\(Int((accuracy * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(accuracy >= 0.8 ? .green : accuracy >= 0.6 ? .orange : .red)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent("待校准样本") {
                Text("\(quality?.pendingCalibrationCount ?? 0) 条").monospacedDigit()
            }

            if let weak = quality?.labelPerformance.filter({ $0.downCount > 0 }), !weak.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("薄弱标签（点踩率高）")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(weak.prefix(5), id: \.labelRaw) { item in
                        HStack {
                            Text(labelDisplayName(item.labelRaw))
                                .font(.caption)
                            Spacer()
                            Text("点踩 \(item.downCount)/\(item.total) · \(Int((item.downRate * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(item.downRate >= 0.5 ? .red : .orange)
                        }
                    }
                }
            }

            if let pairs = quality?.confusionPairs, !pairs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("常混淆标签对")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(Array(pairs.prefix(5).enumerated()), id: \.offset) { _, pair in
                        HStack {
                            Text("\(labelDisplayName(pair.fromLabelRaw)) → \(labelDisplayName(pair.toLabelRaw))")
                                .font(.caption)
                            Spacer()
                            Text("\(pair.isConfirmed ? "实锤" : "疑似") ×\(pair.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(pair.isConfirmed ? .red : .secondary)
                        }
                    }
                }
            }
        } header: {
            Text("识别质量")
        } footer: {
            Text("命中率 = 点赞 / 全部反馈。混淆对来源：点踩后点选了正确意图 = 实锤「判成 X、实际 Y」；仅快照次选标签 = 疑似混淆。")
        }
    }

    private func labelDisplayName(_ raw: String) -> String {
        OmniboxIntentLabel(rawValue: raw)?.displayName ?? raw
    }

    // MARK: 语料

    private var corpusSection: some View {
        Section {
            LabeledContent("有效样本") {
                Text("\(report?.sampleCount ?? 0) 条").monospacedDigit()
            }
            LabeledContent("点赞 / 点踩") {
                Text("\(report?.upCount ?? 0) / \(report?.downCount ?? 0)").monospacedDigit()
            }
            LabeledContent("无概率快照（已剔除）") {
                Text("\(report?.excludedCount ?? 0) 条").monospacedDigit()
            }
        } header: {
            Text("语料")
        } footer: {
            if let report, let reason = report.unreliabilityReason {
                Text("⚠️ \(reason)。样本不足时维持现值，不做推荐。")
            } else {
                Text("语料来自投喂口确认卡的点赞/点踩（自动快照当时的 top1 概率与差距）。")
            }
        }
    }

    // MARK: 推荐

    private var recommendationSection: some View {
        Section {
            if let report {
                candidateRow(title: "现行阈值表现", candidate: report.current, highlight: false)
                candidateRow(title: "推荐阈值表现", candidate: report.recommended, highlight: true)
                Button {
                    AppSettings.intentThresholdOverride = (
                        report.recommendedPolicy.minTopProbability,
                        report.recommendedPolicy.minMargin
                    )
                    override = AppSettings.intentThresholdOverride
                    showAppliedToast = true
                    reload()
                } label: {
                    Label("一键应用推荐阈值", systemImage: "checkmark.seal.fill")
                }
                .disabled(!report.isReliable || report.recommended.policy == report.current.policy)
            } else {
                Text("加载中…").foregroundStyle(.secondary)
            }
        } header: {
            Text("校准结果")
        } footer: {
            Text("排序原则：错误放行（点踩被自动执行）最少优先，其次正确放行最多，再者离经验值最近。宁可少自动执行，不可错自动执行。")
        }
        .overlay(alignment: .bottom) {
            if showAppliedToast {
                Text("已应用，即刻生效")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { showAppliedToast = false }
                    }
            }
        }
    }

    private func candidateRow(title: String, candidate: IntentThresholdCalibrator.Candidate, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(highlight ? .subheadline.bold() : .subheadline)
                .foregroundStyle(highlight ? Color.accentColor : Color.primary)
            Text("阈值 \(String(format: "%.2f", candidate.policy.minTopProbability)) / \(String(format: "%.2f", candidate.policy.minMargin))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("正确放行 \(candidate.correctAccepts) · 错误放行 \(candidate.wrongAccepts) · 过度拦截 \(candidate.wrongRejects) · 正确拦截 \(candidate.correctRejects)")
                .font(.caption2)
                .foregroundStyle(candidate.wrongAccepts > 0 ? .red : .secondary)
            Text("精确率 \(Int((candidate.precision * 100).rounded()))% · 覆盖率 \(Int((candidate.coverage * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 候选网格

    private var candidateSection: some View {
        Section {
            if let ranked = report?.rankedCandidates, !ranked.isEmpty {
                ForEach(0..<min(8, ranked.count), id: \.self) { index in
                    let candidate = ranked[index]
                    HStack {
                        Text("#\(index + 1)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        Text("\(String(format: "%.2f", candidate.policy.minTopProbability)) / \(String(format: "%.2f", candidate.policy.minMargin))")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Text(candidate.wrongAccepts > 0 ? "错放 \(candidate.wrongAccepts)" : "放行 \(candidate.correctAccepts)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(candidate.wrongAccepts > 0 ? .red : .secondary)
                    }
                }
            }
        } header: {
            Text("候选排序（前 8）")
        } footer: {
            Text("网格范围：top1 0.30~0.90、差距 0.05~0.50，步进 0.05。")
        }
    }

    // MARK: 导出

    private var dataSection: some View {
        Section {
            ShareLink(item: exportJSONString()) {
                Label("导出语料 JSON", systemImage: "square.and.arrow.up")
            }
            Button("重新读取语料", action: reload)
        } header: {
            Text("数据")
        } footer: {
            Text("导出内容包含每条反馈的输入、判定标签、结论与概率快照，可用于离线复核阈值。")
        }
    }

    // MARK: - 数据装配

    private func reload() {
        let records = ((try? context.fetch(FetchDescriptor<OmniboxJudgmentFeedback>())) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
        let feedbacks = records.map(\.feedback)
        samples = feedbacks
        report = IntentThresholdCalibrator.calibrate(samples: feedbacks)
        quality = RecognitionQualityStats.report(from: feedbacks)
    }

    private func exportJSONString() -> String {
        struct ExportedSample: Codable {
            let inputText: String
            let labelRaw: String
            let verdict: String
            let topProbability: Double
            let margin: Double
            let runnerUpLabelRaw: String?
            let correctedLabelRaw: String?
            let createdAt: Date
        }
        struct ExportedReport: Codable {
            let sampleCount: Int
            let excludedCount: Int
            let upCount: Int
            let downCount: Int
            let isReliable: Bool
            let unreliabilityReason: String?
            let currentTop: Double
            let currentMargin: Double
            let recommendedTop: Double
            let recommendedMargin: Double
        }
        struct Export: Codable {
            let exportedAt: Date
            let report: ExportedReport?
            let samples: [ExportedSample]
        }

        let export = Export(
            exportedAt: .now,
            report: report.map {
                ExportedReport(
                    sampleCount: $0.sampleCount,
                    excludedCount: $0.excludedCount,
                    upCount: $0.upCount,
                    downCount: $0.downCount,
                    isReliable: $0.isReliable,
                    unreliabilityReason: $0.unreliabilityReason,
                    currentTop: $0.current.policy.minTopProbability,
                    currentMargin: $0.current.policy.minMargin,
                    recommendedTop: $0.recommended.policy.minTopProbability,
                    recommendedMargin: $0.recommended.policy.minMargin
                )
            },
            samples: samples.map {
                ExportedSample(
                    inputText: $0.inputText,
                    labelRaw: $0.labelRaw,
                    verdict: $0.verdict.rawValue,
                    topProbability: $0.topProbability,
                    margin: $0.margin,
                    runnerUpLabelRaw: $0.runnerUpLabelRaw,
                    correctedLabelRaw: $0.correctedLabelRaw,
                    createdAt: $0.createdAt
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(export), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
