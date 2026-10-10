import SwiftUI

/// 欢迎与核心权限初始化向导页面
struct PermissionOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pm = PermissionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var onFinished: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - 头部品牌标语
                    VStack(spacing: 12) {
                        Image("AssistantAppIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)

                        VStack(spacing: 4) {
                            Text("欢迎使用小助 · 核心权限初始化")
                                .font(.title3.bold())
                                .multilineTextAlignment(.center)

                            Text("小助坚持 100% 离线端侧运作，数据绝不上云。\n为了确保待办催办、家与公司学习及语音对话正常生效，请在开始前配置以下 4 项核心权限：")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 16)

                    // 权限准备进度指示
                    HStack {
                        Text("核心权限就绪进度：")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(pm.readyCount) / 4 项已开启")
                            .font(.caption2.bold())
                            .foregroundStyle(pm.areAllCorePermissionsReady ? Color.green : Color.orange)
                    }
                    .padding(.horizontal, 20)

                    // MARK: - 权限卡片列表
                    VStack(spacing: 12) {
                        // 1. 系统通知
                        permissionCard(
                            icon: "bell.badge.fill",
                            color: .red,
                            title: "系统通知提醒",
                            description: "待办到期催办、重要证件/药品临期预警、每日服药闹钟、连续包月扣款提前拦截。",
                            privacyTag: "本地通知 · 零上传",
                            state: pm.notificationStatus
                        ) {
                            Task { await pm.requestNotification() }
                        }

                        // 2. 地理定位
                        permissionCard(
                            icon: "location.fill",
                            color: .blue,
                            title: "地理位置与围栏",
                            description: "常驻地点自主学习（家/公司时空自识别）、到达快递驿站附近弹出取件码提醒。",
                            privacyTag: "硬件围栏 · 低功耗",
                            state: pm.locationStatus
                        ) {
                            pm.requestLocation()
                        }

                        // 3. 麦克风与端侧语音
                        permissionCard(
                            icon: "mic.fill",
                            color: .purple,
                            title: "麦克风与语音识别",
                            description: "离线语音助手双向对话交互、语音备忘录随身录音与端侧离线文字转写。",
                            privacyTag: "端侧识别 · 零录音外传",
                            state: (pm.microphoneStatus.isReady && pm.speechStatus.isReady) ? .authorized : (pm.microphoneStatus == .denied || pm.speechStatus == .denied ? .denied : .notDetermined)
                        ) {
                            Task { await pm.requestMicrophoneAndSpeech() }
                        }

                        // 4. 相册访问
                        permissionCard(
                            icon: "photo.on.rectangle.angled",
                            color: .teal,
                            title: "相册照片存储",
                            description: "重要证件保险箱照片存入、物品收纳拍照防遗忘、自定义主页相册壁纸。",
                            privacyTag: "沙盒加密存储",
                            state: pm.photoStatus
                        ) {
                            Task { await pm.requestPhotoLibrary() }
                        }
                    }
                    .padding(.horizontal, 16)

                    // MARK: - 底部操作按钮
                    VStack(spacing: 12) {
                        if pm.areAllCorePermissionsReady {
                            Button {
                                finishOnboarding()
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.seal.fill")
                                    Text("权限已就绪 · 开始使用我的个人助理 🚀")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.green))
                                .foregroundStyle(.white)
                            }
                        } else {
                            Button {
                                Task {
                                    await pm.requestAllPermissionsSequence()
                                }
                            } label: {
                                HStack {
                                    if pm.isRequestingAll {
                                        ProgressView()
                                            .tint(.white)
                                            .padding(.trailing, 4)
                                    } else {
                                        Image(systemName: "hand.tap.fill")
                                    }
                                    Text(pm.isRequestingAll ? "正在调起系统授权..." : "一键配置全部核心权限")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
                                .foregroundStyle(.white)
                            }
                            .disabled(pm.isRequestingAll)

                            Button {
                                finishOnboarding()
                            } label: {
                                Text("稍后在「设置」中配置，直接进入")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        finishOnboarding()
                    }
                }
            }
            .task {
                pm.refreshAllStatuses()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    pm.refreshAllStatuses()
                }
            }
        }
    }

    private func finishOnboarding() {
        pm.hasCompletedOnboarding = true
        Haptic.success()
        onFinished?()
        dismiss()
    }

    // 单个权限卡片
    private func permissionCard(
        icon: String,
        color: Color,
        title: String,
        description: String,
        privacyTag: String,
        state: PermissionManager.PermissionState,
        onRequest: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(privacyTag)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    if state.isReady {
                        Label("已就绪", systemImage: "checkmark.circle.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                            .foregroundStyle(Color.green)
                    } else if state == .denied {
                        Button {
                            pm.openSystemSettings()
                        } label: {
                            HStack(spacing: 3) {
                                Text("已禁用 · 去系统设置开启")
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(Color.orange)
                        }
                    } else {
                        Button {
                            onRequest()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle.fill")
                                Text("立即授权")
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(state.isReady ? Color.green.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
