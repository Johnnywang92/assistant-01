import SwiftUI

/// 全屏解锁界面（App 处于锁定状态时覆盖显示）
struct AppLockScreen: View {
    @ObservedObject var lockManager = AppLockManager.shared
    @AppStorage("assistant_custom_name") private var assistantName: String = "助手"

    @State private var inputCode: String = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var errorMessage: String?

    private let codeLength = 4

    var body: some View {
        ZStack {
            // 背景毛玻璃与自适应底色
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // 应用图标与名称
                VStack(spacing: 12) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                    Text(assistantName.isEmpty ? "助手" : assistantName)
                        .font(.title2.bold())

                    Text(errorMessage ?? (lockManager.useBiometrics ? "轻触人脸或输入数字密码解锁" : "请输入 4 位数字密码"))
                        .font(.subheadline)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }

                // 4 位数字指示圆点
                HStack(spacing: 20) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        Circle()
                            .fill(index < inputCode.count ? Color.primary : Color.clear)
                            .overlay(
                                Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1.5)
                            )
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.vertical, 8)
                .offset(x: shakeOffset)

                Spacer()

                // 拨号数字键盘
                VStack(spacing: 16) {
                    HStack(spacing: 24) {
                        keypadButton("1")
                        keypadButton("2")
                        keypadButton("3")
                    }
                    HStack(spacing: 24) {
                        keypadButton("4")
                        keypadButton("5")
                        keypadButton("6")
                    }
                    HStack(spacing: 24) {
                        keypadButton("7")
                        keypadButton("8")
                        keypadButton("9")
                    }
                    HStack(spacing: 24) {
                        // 左下角：Face ID 按钮（若开启生物识别）
                        if lockManager.useBiometrics {
                            Button {
                                lockManager.authenticateWithBiometrics()
                            } label: {
                                Image(systemName: "faceid")
                                    .font(.title)
                                    .foregroundStyle(.tint)
                                    .frame(width: 76, height: 76)
                            }
                        } else {
                            Color.clear.frame(width: 76, height: 76)
                        }

                        keypadButton("0")

                        // 右下角：回退/清除
                        Button {
                            if !inputCode.isEmpty {
                                inputCode.removeLast()
                                errorMessage = nil
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } label: {
                            Image(systemName: "delete.left")
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .frame(width: 76, height: 76)
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .padding(.horizontal)
        }
        .onAppear {
            if lockManager.useBiometrics {
                lockManager.authenticateWithBiometrics()
            }
        }
    }

    private func keypadButton(_ digit: String) -> some View {
        Button {
            appendDigit(digit)
        } label: {
            Text(digit)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private func appendDigit(_ digit: String) {
        guard inputCode.count < codeLength else { return }
        inputCode.append(digit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        errorMessage = nil

        if inputCode.count == codeLength {
            verifyCode()
        }
    }

    private func verifyCode() {
        if lockManager.verifyPasscode(inputCode) {
            lockManager.unlockDirectly()
            inputCode = ""
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = "密码错误，请重新输入"
            withAnimation(.default) {
                shakeOffset = 16
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.default) { shakeOffset = -16 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.default) { shakeOffset = 8 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.default) { shakeOffset = 0 }
                inputCode = ""
            }
        }
    }
}

// MARK: - App 锁设置页面

struct AppLockSettingsView: View {
    @ObservedObject var lockManager = AppLockManager.shared

    @State private var showingSetPasscodeSheet = false
    @State private var showingRemoveAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("启用 App 密码锁", isOn: Binding(
                    get: { lockManager.isAppLockEnabled },
                    set: { enabled in
                        if enabled {
                            if !lockManager.hasPasscode {
                                showingSetPasscodeSheet = true
                            } else {
                                lockManager.isAppLockEnabled = true
                            }
                        } else {
                            showingRemoveAlert = true
                        }
                    }
                ))

                if lockManager.isAppLockEnabled {
                    Toggle("允许 Face ID / Touch ID 解锁", isOn: $lockManager.useBiometrics)

                    Picker("自动锁定时间", selection: $lockManager.timeoutOption) {
                        ForEach(LockTimeoutOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                }
            } footer: {
                Text("开启后，打开或切回应用时需验证面容或密码，保护你的快递、证件和个人待办。")
            }

            if lockManager.isAppLockEnabled {
                Section("密码管理") {
                    Button("修改数字密码") {
                        showingSetPasscodeSheet = true
                    }
                    Button("立即锁定 App", role: .destructive) {
                        lockManager.lockNow()
                    }
                }
            }
        }
        .navigationTitle("App 访问锁")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetPasscodeSheet) {
            SetPasscodeSheet()
        }
        .alert("关闭 App 密码锁", isPresented: $showingRemoveAlert) {
            Button("取消", role: .cancel) {}
            Button("关闭", role: .destructive) {
                lockManager.removePasscode()
            }
        } message: {
            Text("关闭后，打开 App 将不再需要验证密码或 Face ID。")
        }
    }
}

// MARK: - 设置数字密码弹窗

struct SetPasscodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var lockManager = AppLockManager.shared

    @State private var step: Int = 1 // 1: 输入新密码，2: 再次确认
    @State private var firstCode: String = ""
    @State private var secondCode: String = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var message: String = "请输入 4 位数字新密码"

    private let codeLength = 4
    private var currentCode: String { step == 1 ? firstCode : secondCode }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)

                    Text(step == 1 ? "设置 4 位应用密码" : "再次确认密码")
                        .font(.title3.bold())

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(step == 2 && currentCode.count == codeLength && firstCode != secondCode ? Color.red : Color.secondary)
                }

                HStack(spacing: 18) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        Circle()
                            .fill(index < currentCode.count ? Color.primary : Color.clear)
                            .overlay(
                                Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1.5)
                            )
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.vertical, 8)
                .offset(x: shakeOffset)

                Spacer()

                // 键盘
                VStack(spacing: 14) {
                    HStack(spacing: 24) {
                        pinButton("1")
                        pinButton("2")
                        pinButton("3")
                    }
                    HStack(spacing: 24) {
                        pinButton("4")
                        pinButton("5")
                        pinButton("6")
                    }
                    HStack(spacing: 24) {
                        pinButton("7")
                        pinButton("8")
                        pinButton("9")
                    }
                    HStack(spacing: 24) {
                        Color.clear.frame(width: 72, height: 72)
                        pinButton("0")
                        Button {
                            if step == 1 && !firstCode.isEmpty {
                                firstCode.removeLast()
                            } else if step == 2 && !secondCode.isEmpty {
                                secondCode.removeLast()
                            }
                        } label: {
                            Image(systemName: "delete.left")
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .frame(width: 72, height: 72)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func pinButton(_ digit: String) -> some View {
        Button {
            appendPinDigit(digit)
        } label: {
            Text(digit)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private func appendPinDigit(_ digit: String) {
        if step == 1 {
            guard firstCode.count < codeLength else { return }
            firstCode.append(digit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if firstCode.count == codeLength {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    step = 2
                    message = "请再次输入以确认"
                }
            }
        } else {
            guard secondCode.count < codeLength else { return }
            secondCode.append(digit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if secondCode.count == codeLength {
                verifyAndSave()
            }
        }
    }

    private func verifyAndSave() {
        if firstCode == secondCode {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            lockManager.setPasscode(firstCode)
            dismiss()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            message = "两次输入的密码不一致，请重试"
            withAnimation(.default) { shakeOffset = 16 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { withAnimation { shakeOffset = -16 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { withAnimation { shakeOffset = 8 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation { shakeOffset = 0 }
                secondCode = ""
            }
        }
    }
}
