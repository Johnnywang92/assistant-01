import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 离线密码管理、随机生成与轮换预警视图
struct PasswordVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PasswordVaultItem.lastRotatedAt) private var passwords: [PasswordVaultItem]
    @StateObject private var auth = BiometricAuthManager()
    @ObservedObject private var bgManager = AppBackgroundManager.shared

    @State private var showingAddSheet = false
    @State private var showingGeneratorSheet = false
    @State private var vaultError: String?
    @State private var migrationReady = false

    var body: some View {
        Group {
            if auth.isUnlocked && migrationReady {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .navigationTitle("密码与安全保险箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if auth.isUnlocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        auth.lock()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) { AddPasswordSheet() }
        .sheet(isPresented: $showingGeneratorSheet) { StandaloneGeneratorSheet() }
        .alert("密码库操作失败", isPresented: Binding(get: { vaultError != nil }, set: { if !$0 { vaultError = nil } })) {
            Button("知道了", role: .cancel) { vaultError = nil }
        } message: { Text(vaultError ?? "") }
        .onAppear {
            do {
                try PasswordVaultCrypto.migrateLegacyRecords(context: context)
                migrationReady = true
            }
            catch { vaultError = error.localizedDescription }
            if !auth.isUnlocked {
                auth.authenticate(reason: "使用 Face ID / Touch ID 解锁密码保险箱")
            }
        }
    }

    private var unlockedContent: some View {
        List {
            Section {
                Text("所有密码完全保存在本设备私有沙盒中，绝不上传云端。支持生成高强度随机密码，并在密码长期未更换时自动提醒轮换更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // 快速工具入口
            Section {
                Button {
                    showingGeneratorSheet = true
                } label: {
                    Label("逻辑记忆与强密码生成器", systemImage: "sparkles")
                }
            }

            // 密码项列表
            Section("我的密码档案 (\(passwords.count))") {
                if passwords.isEmpty {
                    ContentUnavailableView(
                        "暂无密码记录",
                        systemImage: "key",
                        description: Text("点击右上角 + 登记重要账号或生成强密码")
                    )
                } else {
                    ForEach(passwords) { item in
                        PasswordVaultRow(item: item)
                    }
                    .onDelete(perform: deleteItems)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .themedRow()
    }

    private var lockedContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("密码保险箱已锁定")
                .font(.title2.bold())

            Text("为了保护你的敏感账号与重要密码安全，\n请验证 Face ID 或锁屏密码以解锁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                auth.authenticate(reason: "使用 Face ID / Touch ID 解锁密码保险箱")
            } label: {
                Label("点击进行身份验证", systemImage: "faceid")
                    .font(.headline)
                    .frame(maxWidth: 240)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemGroupedBackground))
        .themedAppBackground()
    }

    private func deleteItems(at offsets: IndexSet) {
        for idx in offsets { context.delete(passwords[idx]) }
        try? context.save()
    }
}

struct PasswordVaultRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: PasswordVaultItem
    @State private var isRevealed = false
    @State private var revealError: String?

    private var decryptedPassword: String? { try? PasswordVaultCrypto.decrypt(item.passwordEncrypted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.tr(item.title), systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Text(L10n.tr(item.category))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }

            HStack {
                Text("账号: \(item.account)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = item.account
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("复制账号")
                .accessibilityHint("将账号复制到剪贴板")
            }

            HStack {
                if isRevealed {
                    Text(decryptedPassword ?? "无法解密")
                        .font(.body.monospaced())
                } else {
                    Text("••••••••••••")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? "隐藏密码" : "显示密码")

                Button {
                    guard let password = decryptedPassword else {
                        revealError = "无法解密这条密码，请确认设备安全密钥可用。"
                        return
                    }
                    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: password]], options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("复制密码")
                .accessibilityHint("复制到剪贴板，60 秒后自动失效且仅限本机使用")
            }

            HStack {
                Text("已使用 \(item.usedDays) 天")
                if item.isRotationDue {
                    Text("· 建议轮换更新")
                        .foregroundStyle(.red)
                        .bold()
                } else if item.rotateCycleDays > 0 {
                    Text("· 每 \(item.rotateCycleDays) 天轮换")
                }
                Spacer()
                Button("重置更新日期") {
                    item.lastRotatedAt = .now
                    try? context.save()
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .themedRow()
        .alert("无法复制密码", isPresented: Binding(get: { revealError != nil }, set: { if !$0 { revealError = nil } })) {
            Button("知道了", role: .cancel) { revealError = nil }
        } message: { Text(revealError ?? "") }
    }
}

struct AddPasswordSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var account = ""
    @State private var password = ""
    @State private var category = "日常账号"
    @State private var rotateDays = 90
    @State private var notes = ""
    @State private var mnemonicHint = ""
    @State private var showingGeneratorSheet = false
    @State private var saveError: String?

    let categories = ["日常账号", "工作企业", "银行资产", "路由器设备", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("服务/网站名称（如：企业邮箱、路由器管理后台）", text: $title)
                    TextField("账号/用户名/邮箱", text: $account)
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { c in Text(L10n.tr(c)).tag(c) }
                    }
                }

                Section("密码设置") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("密码", text: $password)
                                .font(.body.monospaced())

                            Button {
                                showingGeneratorSheet = true
                            } label: {
                                Label("智能生成", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if !password.isEmpty {
                            let strength = PasswordSecurityService.evaluateStrength(password: password)
                            let entropy = PasswordSecurityService.estimateEntropy(password: password)

                            HStack(spacing: 8) {
                                Text("强度: \(strength.label)")
                                    .font(.caption.bold())
                                    .foregroundStyle(strength.score >= 3 ? .green : .orange)

                                Text("· \(password.count) 位字符")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text("· ~\(entropy) bits 熵")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if !mnemonicHint.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "lightbulb.fill")
                                            .foregroundStyle(.yellow)
                                        Text("记忆逻辑")
                                            .font(.caption.bold())
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Button("存入备忘") {
                                            if notes.isEmpty {
                                                notes = mnemonicHint
                                            } else if !notes.contains(mnemonicHint) {
                                                notes += "\n" + mnemonicHint
                                            }
                                            Haptic.light()
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                    }

                                    Text(mnemonicHint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }

                Section("安全轮换提醒") {
                    Stepper("每 \(rotateDays) 天提醒更换", value: $rotateDays, in: 30...365, step: 30)
                    TextField("补充安全备忘（可选）", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("添加密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let encrypted = try PasswordVaultCrypto.encrypt(password)
                            let item = PasswordVaultItem(
                                title: title,
                                account: account,
                                passwordEncrypted: encrypted,
                                category: category,
                                notes: notes.isEmpty ? nil : notes,
                                rotateCycleDays: rotateDays
                            )
                            context.insert(item)
                            try context.save()
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                    .disabled(title.isEmpty || password.isEmpty)
                }
            }
            .sheet(isPresented: $showingGeneratorSheet) {
                StandaloneGeneratorSheet { generatedResult in
                    self.password = generatedResult.password
                    self.mnemonicHint = generatedResult.mnemonicHint
                }
            }
            .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("知道了", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }
}

/// 逻辑记忆与高熵强密码生成器独立弹窗
struct StandaloneGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var onSelectPassword: ((GeneratedPasswordResult) -> Void)?

    @State private var selectedMode: PasswordGenerationMode = .memorablePhrase
    @State private var wordCount: Int = 3
    @State private var separator: String = "-"
    @State private var includeDigits: Bool = true
    @State private var includeSymbols: Bool = true
    @State private var classicLength: Int = 16

    @State private var currentResult: GeneratedPasswordResult = PasswordSecurityService.generateSmartPassword()

    let separatorOptions = ["-", "_", ".", "!", "#", "@"]

    var body: some View {
        NavigationStack {
            Form {
                // 1. 生成结果与记忆口诀展示
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // 密码文本与一键操作
                        Text(currentResult.password)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)

                        // 记忆逻辑卡片（重要：让用户容易记忆）
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "brain.head.profile")
                                    .foregroundStyle(.indigo)
                                Text("记忆逻辑与口诀")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.indigo)
                                Spacer()
                                Text("不易破解 · 好记")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(currentResult.mnemonicHint)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(Color.indigo.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        // 密码安全指标
                        HStack(spacing: 12) {
                            Label("强度: \(currentResult.strengthLabel)", systemImage: "shield.lefthalf.filled")
                                .font(.caption.bold())
                                .foregroundStyle(currentResult.strengthScore >= 3 ? .green : .orange)

                            Text("· \(currentResult.password.count) 位字符")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text("· 约 \(currentResult.entropyBits) 位熵")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Spacer()
                        }

                        Divider()

                        // 操作按钮组
                        HStack(spacing: 12) {
                            Button {
                                regenerate()
                                Haptic.light()
                            } label: {
                                Label("换一个", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            if let onSelect = onSelectPassword {
                                Button {
                                    onSelect(currentResult)
                                    Haptic.success()
                                    dismiss()
                                } label: {
                                    Label("填入密码", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
                                    UIPasteboard.general.string = currentResult.password
                                    Haptic.success()
                                    dismiss()
                                } label: {
                                    Label("复制密码", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("生成结果与记忆助记")
                }

                // 2. 逻辑记忆生成模式切换
                Section {
                    Picker("生成模式", selection: $selectedMode) {
                        ForEach(PasswordGenerationMode.allCases) { mode in
                            Label(L10n.tr(mode.rawValue), systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedMode) { _, _ in regenerate() }

                    Text(selectedMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("记忆模式选择")
                }

                // 3. 详细参数微调
                Section {
                    if selectedMode == .classicRandom {
                        Stepper("密码长度: \(classicLength) 位", value: $classicLength, in: 8...32)
                            .onChange(of: classicLength) { _, _ in regenerate() }
                    } else {
                        Stepper("词语/音节数量: \(wordCount) 组", value: $wordCount, in: 2...5)
                            .onChange(of: wordCount) { _, _ in regenerate() }

                        Picker("连接分隔符", selection: $separator) {
                            ForEach(separatorOptions, id: \.self) { sep in
                                Text(sep == "-" ? "- (中划线)" : (sep == "_" ? "_ (下划线)" : sep)).tag(sep)
                            }
                        }
                        .onChange(of: separator) { _, _ in regenerate() }
                    }

                    Toggle("包含数字 (如年份/两位随机数)", isOn: $includeDigits)
                        .onChange(of: includeDigits) { _, _ in regenerate() }

                    Toggle("包含特殊字符 (如 ! # @ $)", isOn: $includeSymbols)
                        .onChange(of: includeSymbols) { _, _ in regenerate() }
                } header: {
                    Text("规则与复杂度配置")
                } footer: {
                    Text("💡 科学原理：人类大脑擅长记忆具象画面和语义关联，计算机暴力破解依靠指数穷举。使用 3 组自然意象词搭配符号与数字，密码熵达 50~70 bits，暴力穷举需数千万年，既固若金汤又过目不忘。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("记忆强密码生成器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onAppear {
                regenerate()
            }
        }
    }

    private func regenerate() {
        currentResult = PasswordSecurityService.generateSmartPassword(
            mode: selectedMode,
            wordCount: wordCount,
            separator: separator,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols,
            randomLength: classicLength
        )
    }
}
