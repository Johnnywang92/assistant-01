import SwiftUI

struct WatchParcelsView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var parcels: [WidgetTodoEntry] {
        store.displaySnapshot.parcels
    }

    var body: some View {
        NavigationStack {
            if let current = parcels.first {
                ScrollView {
                    VStack(spacing: 8) {
                        // 驿站名称与剩余件数
                        HStack {
                            Text(current.stationName ?? "待取包裹")
                                .font(.caption.bold())
                                .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.orange)
                                .lineLimit(1)
                            Spacer()
                            Text("剩 \(parcels.count) 件")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        // 超大号取件码铭牌
                        Text(current.pickupCode ?? current.title)
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange.opacity(isLuminanceReduced ? 0.08 : 0.18))
                            )

                        Text(current.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        // 一键销号自动跳到下一件
                        Button {
                            store.sendCommand(
                                .completeTodo(current.id),
                                feedbackToast: parcels.count > 1 ? "已取件，切换下一件" : "全部包裹已取齐 🎉"
                            )
                        } label: {
                            Label(parcels.count > 1 ? "已取件 · 下一件" : "已取件 ✓", systemImage: "checkmark.circle.fill")
                                .font(.footnote.bold())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        if parcels.count > 1 {
                            Button {
                                for item in parcels {
                                    store.sendCommand(.completeTodo(item.id))
                                }
                                store.showBanner("全部取齐 🎉")
                            } label: {
                                Text("全部取齐 (\(parcels.count)件)")
                                    .font(.caption2)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .navigationTitle("取件码")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有待取的快递")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("取件码")
            }
        }
    }
}
