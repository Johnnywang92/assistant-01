import SwiftUI
import WatchKit

struct WatchMoodCheckInView: View {
    @EnvironmentObject private var store: WatchStore

    @State private var mood: Int = 3
    @State private var energy: Int = 3
    @State private var stress: Int = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                // 点击直接循环加分（1→2→3→4→5→1），不抢占数码表冠，表冠全程保留给上下切页
                HStack(spacing: 6) {
                    scoreCard(title: "心情", score: $mood, color: .pink)
                    scoreCard(title: "精力", score: $energy, color: .green)
                    scoreCard(title: "压力", score: $stress, color: .orange)
                }

                Text("轻点卡片切换分值 (1~5)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    store.sendCommand(
                        .logMood(mood: mood, energy: energy, stress: stress),
                        feedbackToast: "心情打卡完成 ✓"
                    )
                } label: {
                    Label("完成打卡", systemImage: "heart.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.pink)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .navigationTitle("心情打卡")
            .onAppear {
                if let existing = store.displaySnapshot.todayMood {
                    mood = existing.mood
                    energy = existing.energy
                    stress = existing.stress
                }
            }
        }
    }

    private func scoreCard(title: String, score: Binding<Int>, color: Color) -> some View {
        Button {
            score.wrappedValue = (score.wrappedValue % 5) + 1
            WKInterfaceDevice.current().play(.click)
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(score.wrappedValue)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                // 底部 5 格小圆点直观展示档位
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { level in
                        Circle()
                            .fill(level <= score.wrappedValue ? color : color.opacity(0.22))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
    }
}
