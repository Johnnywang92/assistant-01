import AssistantCore
import SwiftUI

struct WatchWaterView: View {
    @EnvironmentObject private var store: WatchStore

    private var waterML: Double {
        store.displaySnapshot.todayWaterML
    }

    private var goalML: Double {
        max(store.displaySnapshot.waterGoalML, 500)
    }

    private var progress: Double {
        min(waterML / goalML, 1.0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // 顶部紧凑进度卡（左侧水量与达标率，右侧圆环进度条）
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(waterML))")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("ml")
                                .font(.caption2.bold())
                                .foregroundStyle(.cyan)
                        }
                        Text("目标 \(Int(goalML))ml · \(Int(progress * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .stroke(Color.cyan.opacity(0.22), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: progress >= 1.0 ? "checkmark" : "drop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    .frame(width: 36, height: 36)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.cyan.opacity(0.14))
                )

                // 两排双列大按钮网格
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        waterButton(volume: 150, label: "+150ml")
                        waterButton(volume: 250, label: "+250ml")
                    }
                    GridRow {
                        waterButton(volume: 350, label: "+350ml")
                        waterButton(volume: 500, label: "+500ml")
                    }
                }
            }
            .padding(.horizontal, 4)
            .navigationTitle("喝水 +1")
        }
    }

    private func waterButton(volume: Double, label: String) -> some View {
        Button {
            store.sendCommand(
                .addWater(beverageRaw: HydrationBeverageType.plainWater.rawValue, volumeML: volume),
                feedbackToast: "已补水 +\(Int(volume))ml 💧"
            )
        } label: {
            Text(label)
                .font(.footnote.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cyan.opacity(0.25))
                )
                .foregroundStyle(.cyan)
        }
        .buttonStyle(.plain)
    }
}
