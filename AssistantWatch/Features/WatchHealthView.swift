import SwiftUI

struct WatchHealthView: View {
    @EnvironmentObject private var store: WatchStore

    private var health: WatchHealthSnapshot? {
        store.displaySnapshot.healthSnapshot
    }

    var body: some View {
        VStack(spacing: 6) {
            // 1. 顶部双指数并排卡片（身体活力 & 身心愉悦）
            HStack(spacing: 6) {
                scoreCard(
                    title: "身体活力",
                    score: health?.vitalityScore,
                    badge: health?.vitalityBadge ?? "待同步",
                    color: .green
                )
                scoreCard(
                    title: "身心愉悦",
                    score: health?.pleasureScore,
                    badge: health?.pleasureBadge ?? "待同步",
                    color: .cyan
                )
            }

            // 2. 四项生理体征 2x2 紧凑网格
            Grid(horizontalSpacing: 6, verticalSpacing: 5) {
                GridRow {
                    metricPill(
                        icon: "bed.double.fill",
                        label: "睡眠",
                        value: health?.sleepHours.map { String(format: "%.1fh", $0) } ?? "--",
                        tint: .indigo
                    )
                    metricPill(
                        icon: "waveform.path.ecg",
                        label: "HRV",
                        value: health?.hrvMS.map { String(format: "%.0fms", $0) } ?? "--",
                        tint: .pink
                    )
                }
                GridRow {
                    metricPill(
                        icon: "heart.fill",
                        label: "静息",
                        value: health?.restingHR.map { String(format: "%.0f", $0) } ?? "--",
                        tint: .red
                    )
                    metricPill(
                        icon: "figure.walk",
                        label: "步数",
                        value: health?.steps.map { "\($0)" } ?? "--",
                        tint: .orange
                    )
                }
            }

            // 3. 一句话调养关怀或快捷跳转
            if let advice = health?.headlineAdvice, !advice.isEmpty {
                Text(advice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
            } else {
                HStack(spacing: 6) {
                    Button {
                        store.selectedTab = .mood
                    } label: {
                        Label("记心情", systemImage: "face.smiling")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.pink.opacity(0.22)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.selectedTab = .water
                    } label: {
                        Label("记喝水", systemImage: "drop.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.cyan.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .navigationTitle("身心状态")
    }

    private func scoreCard(title: String, score: Int?, badge: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(score.map { "\($0)" } ?? "--")
                    .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                if score != nil {
                    Text("分")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Text(badge)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.14))
        )
    }

    private func metricPill(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}
