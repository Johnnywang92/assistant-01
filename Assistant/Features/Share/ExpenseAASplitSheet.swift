import AssistantCore
import SwiftData
import SwiftUI

/// 记账面对面 AA 分摊配置与投送面板
struct ExpenseAASplitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ExpenseRecord

    @State private var splitCount: Int = 2
    @State private var note: String = "聚餐 AA 分摊"
    @State private var isShowingNearbySheet: Bool = false
    @State private var generatedEnvelope: UniversalShareEnvelope?
    @State private var airdropItems: [Any] = []
    @State private var showAirDropSheet: Bool = false
    @State private var toastMessage: String? = nil

    private var perPersonAmount: Double {
        let count = max(splitCount, 1)
        let amount = record.amount / Double(count)
        return (amount * 100).rounded() / 100
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. 原账目基本信息卡片
                    VStack(spacing: 8) {
                        Text(record.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("¥")
                                .font(.title3.bold())
                                .foregroundStyle(Color.accentColor)
                            Text(String(format: "%.2f", record.amount))
                                .font(.system(size: 38, weight: .black, design: .rounded))
                                .foregroundStyle(.primary)
                        }

                        Text("账单原总额 · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    // 2. AA 平摊参数配置
                    VStack(spacing: 16) {
                        // 平摊人数调节
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("平摊总人数")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text("包含你在内的所有共同出资人")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Stepper(value: $splitCount, in: 2...20) {
                                Text("\(splitCount) 人")
                                    .font(.headline.monospaced().bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .fixedSize()
                        }

                        Divider()

                        // 每人分摊金额大字
                        HStack {
                            Text("每人应记入")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("¥")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.accentColor)
                                Text(String(format: "%.2f", perPersonAmount))
                                    .font(.title2.bold().monospaced())
                                    .foregroundStyle(.primary)
                            }
                        }

                        Divider()

                        // 备注说明
                        HStack {
                            Text("分摊备注")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            TextField("如：老友聚餐/周末露营", text: $note)
                                .font(.subheadline)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .padding(.horizontal, 20)

                    // 3. 投送说明提示
                    HStack(spacing: 10) {
                        Image(systemName: "wave.3.forward.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("无需好友，碰一碰即可入账")
                                .font(.subheadline.bold())
                            Text("对方手机靠近打开小助，或扫描生成的二维码，账单将直接以「¥\(String(format: "%.2f", perPersonAmount))」记入对方本地账本。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    .padding(.horizontal, 20)

                    // 4. 发起碰一碰投送按钮
                    Button {
                        startNearbySharing()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "wave.3.forward.circle.fill")
                                .font(.headline)
                            Text("开启面对面碰一碰 / 扫码分摊")
                                .font(.headline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // 5. 复制微信口令 & AirDrop .assistant 文件
                    HStack(spacing: 12) {
                        Button {
                            copyAAToken()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text("复制微信 AA 口令")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            shareViaAirDrop()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "airdrop")
                                Text("AirDrop 投送")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("面对面 AA 分摊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .fullScreenCover(item: $generatedEnvelope) { env in
                NearbyInteractionSheet(envelope: env)
            }
            .sheet(isPresented: $showAirDropSheet, onDismiss: { airdropItems = [] }) {
                ShareActivityView(activityItems: airdropItems)
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
    }

    private var currentEnvelope: UniversalShareEnvelope {
        UniversalShareEnvelope.forExpenseAA(
            record: record,
            splitCount: splitCount,
            splitAmount: perPersonAmount,
            note: note.isEmpty ? "AA分摊" : note
        )
    }

    private func startNearbySharing() {
        self.generatedEnvelope = currentEnvelope
    }

    private func copyAAToken() {
        let text = currentEnvelope.generateShareText()
        UIPasteboard.general.string = text
        Haptic.success()
        toastMessage = "AA 分摊口令已复制！发给好友后对方打开小助即可一键入账"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if toastMessage?.contains("AA 分摊口令") == true {
                toastMessage = nil
            }
        }
    }

    private func shareViaAirDrop() {
        if let fileURL = AssistantPackageService.createPackageFile(for: currentEnvelope) {
            self.airdropItems = [fileURL]
            self.showAirDropSheet = true
            Haptic.selection()
        }
    }
}
