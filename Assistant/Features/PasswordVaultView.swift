import SwiftData
import SwiftUI

/// 离线密码管理、随机生成与轮换预警视图
struct PasswordVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PasswordVaultItem.lastRotatedAt) private var passwords: [PasswordVaultItem]

    @State private var showingAddSheet = false
    @State private var showingGeneratorSheet = false

    var body: some View {
        List {
            Section {
                Text("所有密码完全保存在本设备离线数据库中，绝不上传云端。支持生成高强度随机密码，并在密码长期未更换时自动提醒轮换更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // 快速工具入口
            Section {
                Button {
                    showingGeneratorSheet = true
                } label: {
                    Label("随机强密码生成器", systemImage: "dice.fill")
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
        .navigationTitle("密码与安全保险箱")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) { AddPasswordSheet() }
        .sheet(isPresented: $showingGeneratorSheet) { StandaloneGeneratorSheet() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(item.title, systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Text(item.category)
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
            }

            HStack {
                if isRevealed {
                    Text(item.passwordEncrypted)
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

                Button {
                    UIPasteboard.general.string = item.passwordEncrypted
                } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
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

    let categories = ["日常账号", "工作企业", "银行资产", "路由器设备", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("服务/网站名称（如：企业邮箱、路由器管理后台）", text: $title)
                    TextField("账号/用户名/邮箱", text: $account)
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { c in Text(c).tag(c) }
                    }
                }

                Section("密码设置") {
                    HStack {
                        TextField("密码", text: $password)
                        Button("随机生成") {
                            password = PasswordSecurityService.generatePassword()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if !password.isEmpty {
                        let strength = PasswordSecurityService.evaluateStrength(password: password)
                        HStack {
                            Text("密码强度: \(strength.label)")
                                .font(.caption)
                                .foregroundStyle(strength.score >= 3 ? .green : .orange)
                            Spacer()
                            Text("\(password.count) 位字符")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("安全轮换提醒") {
                    Stepper("每 \(rotateDays) 天提醒更换", value: $rotateDays, in: 30...365, step: 30)
                    TextField("补充安全备忘（可选）", text: $notes)
                }
            }
            .navigationTitle("添加密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let item = PasswordVaultItem(
                            title: title,
                            account: account,
                            passwordEncrypted: password,
                            category: category,
                            notes: notes.isEmpty ? nil : notes,
                            rotateCycleDays: rotateDays
                        )
                        context.insert(item)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.isEmpty || password.isEmpty)
                }
            }
        }
    }
}

struct StandaloneGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var length = 16
    @State private var includeSymbols = true
    @State private var includeDigits = true
    @State private var generatedPassword = PasswordSecurityService.generatePassword()

    var body: some View {
        NavigationStack {
            Form {
                Section("生成结果") {
                    Text(generatedPassword)
                        .font(.title3.monospaced().bold())
                        .padding(.vertical, 8)

                    HStack {
                        Button("重新生成", systemImage: "arrow.clockwise") {
                            regenerate()
                        }
                        Spacer()
                        Button("复制密码", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = generatedPassword
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("密码规则配置") {
                    Stepper("密码长度: \(length) 位", value: $length, in: 8...32)
                        .onChange(of: length) { _, _ in regenerate() }
                    Toggle("包含特殊字符 (!@#$%^&*)", isOn: $includeSymbols)
                        .onChange(of: includeSymbols) { _, _ in regenerate() }
                    Toggle("包含数字 (0-9)", isOn: $includeDigits)
                        .onChange(of: includeDigits) { _, _ in regenerate() }
                }
            }
            .navigationTitle("随机强密码生成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }

    private func regenerate() {
        generatedPassword = PasswordSecurityService.generatePassword(
            length: length,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
    }
}
