import Foundation

// MARK: - 识别质量统计（判别层质检出口）

/// 判别质量报告：命中率、薄弱标签、常混淆标签对、待校准样本数。
///
/// 数据源是投喂口确认卡攒下的 `JudgmentFeedback`（点赞/点踩 + 概率快照）。
/// 纯逻辑、无 I/O——App 侧只负责取数与展示，计算进 Core 才能被 `swift test` 覆盖。
public struct RecognitionQualityReport: Equatable, Sendable {
    /// 单个标签的表现。
    public struct LabelPerformance: Equatable, Sendable {
        public let labelRaw: String
        public let total: Int
        public let upCount: Int
        public let downCount: Int
        /// 点踩率 = down / total（0~1）。无样本时为 0。
        public let downRate: Double

        public init(labelRaw: String, total: Int, upCount: Int, downCount: Int) {
            self.labelRaw = labelRaw
            self.total = total
            self.upCount = upCount
            self.downCount = downCount
            self.downRate = total > 0 ? Double(downCount) / Double(total) : 0
        }
    }

    /// 一对混淆标签：判成了 `fromLabelRaw`，实际是 `toLabelRaw`。
    public struct ConfusionPair: Equatable, Sendable {
        public let fromLabelRaw: String
        public let toLabelRaw: String
        public let count: Int
        /// true = 实锤（用户点踩后点选了正确标签）；false = 疑似（点踩但只快照了次选标签）。
        public let isConfirmed: Bool

        public init(fromLabelRaw: String, toLabelRaw: String, count: Int, isConfirmed: Bool) {
            self.fromLabelRaw = fromLabelRaw
            self.toLabelRaw = toLabelRaw
            self.count = count
            self.isConfirmed = isConfirmed
        }
    }

    /// 反馈总数（含无概率快照的历史样本）。
    public let sampleCount: Int
    public let upCount: Int
    public let downCount: Int
    /// 命中率 = up / (up + down)。无反馈时为 nil（显示「—」而不是假 100%）。
    public let accuracy: Double?
    /// 各标签表现，按点踩率降序、同率按样本数降序（薄弱标签在前）。
    public let labelPerformance: [LabelPerformance]
    /// 混淆标签对，实锤在前，各组内按次数降序。
    public let confusionPairs: [ConfusionPair]
    /// 带 topProbability 快照、可参与阈值校准的样本数。
    public let pendingCalibrationCount: Int
}

/// 从反馈语料计算判别质量。确定性纯函数，同输入必同输出。
public enum RecognitionQualityStats {
    /// - Parameter samples: 全量判别反馈（无需预过滤，函数内部自行剔除无效标签）。
    public static func report(from samples: [JudgmentFeedback]) -> RecognitionQualityReport {
        var up = 0
        var down = 0
        var pendingCalibration = 0
        var labelTotals: [String: (up: Int, down: Int)] = [:]
        var confirmedPairs: [String: Int] = [:]   // "from→to" -> count
        var suspectedPairs: [String: Int] = [:]

        for sample in samples {
            switch sample.verdict {
            case .up: up += 1
            case .down: down += 1
            }
            if sample.topProbability > 0 {
                pendingCalibration += 1
            }

            let from = sample.labelRaw
            if !from.isEmpty {
                var entry = labelTotals[from] ?? (0, 0)
                if sample.verdict == .up { entry.up += 1 } else { entry.down += 1 }
                labelTotals[from] = entry
            }

            // 混淆对：点踩才有「判错」可言；点赞不产生混淆。
            guard sample.verdict == .down, !from.isEmpty else { continue }
            if let corrected = sample.correctedLabelRaw,
               !corrected.isEmpty, corrected != from {
                confirmedPairs["\(from)→\(corrected)", default: 0] += 1
            } else if let runnerUp = sample.runnerUpLabelRaw,
                      !runnerUp.isEmpty, runnerUp != from {
                suspectedPairs["\(from)→\(runnerUp)", default: 0] += 1
            }
        }

        let labelPerformance = labelTotals.map { raw, counts in
            RecognitionQualityReport.LabelPerformance(
                labelRaw: raw,
                total: counts.up + counts.down,
                upCount: counts.up,
                downCount: counts.down
            )
        }
        .sorted {
            if $0.downRate != $1.downRate { return $0.downRate > $1.downRate }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.labelRaw < $1.labelRaw
        }

        let confirmed = confirmedPairs.map { key, count in
            let parts = key.split(separator: "→")
            return RecognitionQualityReport.ConfusionPair(
                fromLabelRaw: String(parts[0]),
                toLabelRaw: String(parts.count > 1 ? parts[1] : ""),
                count: count,
                isConfirmed: true
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.fromLabelRaw != $1.fromLabelRaw { return $0.fromLabelRaw < $1.fromLabelRaw }
            return $0.toLabelRaw < $1.toLabelRaw
        }

        let suspected = suspectedPairs.map { key, count in
            let parts = key.split(separator: "→")
            return RecognitionQualityReport.ConfusionPair(
                fromLabelRaw: String(parts[0]),
                toLabelRaw: String(parts.count > 1 ? parts[1] : ""),
                count: count,
                isConfirmed: false
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.fromLabelRaw != $1.fromLabelRaw { return $0.fromLabelRaw < $1.fromLabelRaw }
            return $0.toLabelRaw < $1.toLabelRaw
        }

        let totalFeedback = up + down
        return RecognitionQualityReport(
            sampleCount: samples.count,
            upCount: up,
            downCount: down,
            accuracy: totalFeedback > 0 ? Double(up) / Double(totalFeedback) : nil,
            labelPerformance: labelPerformance,
            confusionPairs: confirmed + suspected,
            pendingCalibrationCount: pendingCalibration
        )
    }
}
