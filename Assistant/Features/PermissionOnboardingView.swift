import SwiftUI

/// 全局权限检查与集中授权中心
struct PermissionOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pm = PermissionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var onFinished: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: - 头部品牌标语
                    headerSection

                    // MARK: - 权限准备进度指示
                    readinessProgressCard

                    // MARK: - 核心日常与交互权限
                    VStack(alignment: .leading, spacing: 12) {
                        Text("核心基础与交互")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

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
                    }

                    // MARK: - 智能感知与健康关怀权限
                    VStack(alignment: .leading, spacing: 12) {
                        Text("智能感知与健康关怀")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 12) {
                            // 5. Apple 健康
                            permissionCard(
                                icon: "heart.text.square.fill",
                                color: .pink,
                                title: "Apple 健康数据",
                                description: "读取心率变异性(HRV)、睡眠分期与静息心率以推断愉悦指数，同步饮水打卡。",
                                privacyTag: "端侧分析 · 绝不上云",
                                state: pm.healthStatus
                            ) {
                                Task { await pm.requestHealth() }
                            }

                            // 6. 相机拍摄
                            permissionCard(
                                icon: "camera.fill",
                                color: .orange,
                                title: "相机拍摄与扫码",
                                description: "扫描快递取件码上岛、小票拍照智能解析自动记账、证件翻拍存入保险箱。",
                                privacyTag: "实时取景 · 本地解析",
                                state: pm.cameraStatus
                            ) {
                                Task { await pm.requestCamera() }
                            }

                            // 7. 系统日历
                            permissionCard(
                                icon: "calendar",
                                color: .indigo,
                                title: "系统日历协同",
                                description: "在今日待办与日程中心并排呈现系统日历日程，智能避免行程冲突。",
                                privacyTag: "双向只读 · 隐私安全",
                                state: pm.calendarStatus
                            ) {
                                Task { await pm.requestCalendar() }
                            }

                            // 8. 运动与健身
                            permissionCard(
                                icon: "figure.walk.motion",
                                color: .green,
                                title: "运动与健身感知",
                                description: "乘车/骑行状态精准识别，在到站下车前自动提醒防遗漏清点随身物品。",
                                privacyTag: "低功耗协处理器",
                                state: pm.motionStatus
                            ) {
                                Task { await pm.requestMotion() }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // MARK: - 底部操作按钮
                    bottomActionSection
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
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

    // MARK: - 头部标语

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image("AssistantAppIcon")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text(pm.hasCompletedOnboarding ? "系统权限检查与配置中心" : "欢迎使用小助 · 核心权限初始化")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("所有权限均在设备本机运行，赋予后可直接在当前页面生效。若不便开启也可随时在系统设置中调整：")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - 进度卡片

    private var readinessProgressCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("功能权限就绪度：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pm.readyCount) / \(pm.totalCount) 项已开启")
                    .font(.caption.bold())
                    .foregroundStyle(pm.areAllCorePermissionsReady ? Color.green : Color.orange)
            }

            ProgressView(value: Double(pm.readyCount), total: Double(pm.totalCount))
                .tint(pm.areAllCorePermissionsReady ? Color.green : Color.orange)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
    }

    // MARK: - 底部操作按钮

    private var bottomActionSection: some View {
        VStack(spacing: 12) {
            if pm.areAllCorePermissionsReady {
                Button {
                    finishOnboarding()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                        Text("全量权限已就绪 · 体验完整功能 🚀")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: AppRadius.banner).fill(Color.green))
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
                        Text(pm.isRequestingAll ? "正在调起系统授权..." : "一键配置全部待授权项目")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: AppRadius.banner).fill(Color.accentColor))
                    .foregroundStyle(.white)
                }
                .disabled(pm.isRequestingAll)

                Button {
                    finishOnboarding()
                } label: {
                    Text(pm.hasCompletedOnboarding ? "返回上一页" : "稍后在「设置」中配置，直接进入")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func finishOnboarding() {
        pm.hasCompletedOnboarding = true
        Haptic.success()
        onFinished?()
        dismiss()
    }

    // MARK: - 单个权限卡片

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
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.tr(title))
                        .font(.subheadline.bold())
                    Spacer()
                    Text(L10n.tr(privacyTag))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                }

                Text(L10n.tr(description))
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
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .stroke(state.isReady ? Color.green.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
