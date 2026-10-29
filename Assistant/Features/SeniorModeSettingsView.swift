import SwiftUI

/// 老年人关怀模式与大字设置视图
struct SeniorModeSettingsView: View {
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sampleTestText: String = "下午 3 点吃降压药 1 片，饭后温水服用。"

    var body: some View {
        Form {
            // 1. 关怀模式主开关醒目大卡片
            Section {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(seniorManager.isSeniorModeEnabled ? Color.orange.opacity(0.18) : Color(.tertiarySystemFill))
                                .frame(width: 58, height: 58)

                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(seniorManager.isSeniorModeEnabled ? Color.orange : Color.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("长辈关怀大字模式")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)

                            Text("字号放大、高对比度黑度加深、大触控区与贴心大声语音朗读")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Toggle(isOn: $seniorManager.isSeniorModeEnabled) {
                        Text(seniorManager.isSeniorModeEnabled ? "模式已开启" : "点击开启长辈模式")
                            .font(.headline)
                            .foregroundStyle(seniorManager.isSeniorModeEnabled ? Color.orange : Color.primary)
                    }
                    .tint(.orange)
                    .onChange(of: seniorManager.isSeniorModeEnabled) { _, enabled in
                        if enabled {
                            Haptic.success()
                        } else {
                            Haptic.warning()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            // 2. 实时效果预览卡片
            Section("大字实时效果预览") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("实时展示样例", systemImage: "eye.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("字号：\(seniorManager.fontScale.title)")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }

                    // 样例 A: 服药提醒
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "pill.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("💊 降压药 (络活喜)")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(seniorManager.isHighContrastEnabled ? .primary : .primary)
                                Spacer()
                                Text("15:00")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Text("每日一次，每次 1 片，温水送服")
                                .font(.subheadline)
                                .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

                    // 样例 B: 快递取件码
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shippingbox.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .frame(width: 36, height: 36)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text("📦 菜鸟驿站快递待取")
                                .font(.headline)
                                .fontWeight(.bold)

                            HStack(spacing: 6) {
                                Text("取件码：")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("3-2-104")
                                    .font(.title3.bold().monospaced())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

                    if seniorManager.isVoiceBroadcastEnabled {
                        Button {
                            seniorManager.speakSenior(text: "降压药，每日一次每次1片。菜鸟驿站快递，取件码三杠二杠一零四。")
                        } label: {
                            HStack {
                                Image(systemName: seniorManager.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(.orange)
                                Text(seniorManager.isSpeaking ? "正在清晰大声朗读中..." : "点击试听长辈大声语音播报")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.orange)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            // 3. 字号大小调节
            Section {
                Picker("大字字体档位", selection: Binding(
                    get: { seniorManager.fontScale },
                    set: { seniorManager.fontScale = $0 }
                )) {
                    ForEach(SeniorFontScale.allCases) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                Text(seniorManager.fontScale.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("字体大小选择")
            } footer: {
                Text("选择档位后，待办、档案、记账、出行及弹窗所有界面均会自动以清晰大字呈现。")
            }

            // 4. 辅助视听与无障碍功能
            Section("无障碍与视听辅助") {
                Toggle("超高对比度 (文字更黑更清晰)", isOn: $seniorManager.isHighContrastEnabled)
                    .tint(.orange)

                Toggle("一键大声语音播报 (TTS)", isOn: $seniorManager.isVoiceBroadcastEnabled)
                    .tint(.orange)

                Toggle("放大点击按钮响应区域 (防抖防误触)", isOn: $seniorManager.isLargeTouchTargetsEnabled)
                    .tint(.orange)
            }

            // 5. 使用建议
            Section("写给家属与长辈的贴心提示") {
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint(icon: "checkmark.circle.fill", text: "开启后，可在待办卡片右侧直接点击 🔊 喇叭大声朗读取件码和服药提醒。")
                    bulletPoint(icon: "checkmark.circle.fill", text: "首页悬浮语音球将自动放大，按住悬浮球即可说话快速记录生活琐事。")
                    bulletPoint(icon: "checkmark.circle.fill", text: "所有打卡与完成手势带有更清晰的清脆震动反馈，确保长辈明确感知操作成功。")
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("老年人大字关怀模式")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
                .font(.headline)
            }
        }
    }

    @ViewBuilder
    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            Text(L10n.tr(text))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
