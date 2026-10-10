import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 数据备份、迁移与批量导入视图
struct DataMigrationView: View {
    @Environment(\.modelContext) private var context
    @State private var migrationService: DataMigrationService?

    // 导出状态与 PIN 码设置
    @State private var showSetPinSheet = false
    @State private var exportedData: Data?
    @State private var exportFileName: String = "Assistant_Migration.json"
    @State private var exportTempURL: URL?
    @State private var exportSuccessNotice: String?

    // 导入与 PIN 码解锁状态
    @State private var showFileImporter = false
    @State private var showUnlockPinSheet = false
    @State private var pendingEnvelope: EncryptedBackupEnvelope?
    @State private var unlockErrorMessage: String?
    @State private var pendingPackage: BackupPackage?
    @State private var inspectionSummary: BackupInspectionSummary?
    @State private var selectedStrategy: RestoreStrategy = .merge
    @State private var isRestoring = false
    @State private var restoreResultText: String?

    // 批量录入状态
    @State private var batchText = ""
    @State private var batchType: BatchImportType = .anniversary
    @State private var batchResultNotice: String?

    enum BatchImportType: String, CaseIterable, Identifiable {
        case anniversary = "纪念日 / 生日"
        case password = "账号与密码 (CSV)"
        case todo = "多行待办清单"

        var id: String { rawValue }

        var placeholder: String {
            switch self {
            case .anniversary:
                return "格式：名称, 日期(yyyy-MM-dd), 分类(可选), 备注(可选)\n例如：\n恋爱纪念日, 2022-05-20, 恋爱情侣, 周年约会\n妈妈生日, 1970-10-15, 家人亲友, 准备买围巾"
            case .password:
                return "格式：服务名, 账号, 密码, 分类(可选), 备注(可选)\n例如：\n公司网盘, user@company.com, P@ssw0rd123, 工作, 开启了2FA\n路由器后台, admin, admin888, 设备, 192.168.1.1"
            case .todo:
                return "每行一条待办事项：\n例如：\n去物业拿钥匙\n买滤水器滤芯\n整理下个月差旅发票"
            }
        }
    }

    var body: some View {
        List {
            // 1. 本地数据统计
            Section {
                let stats = (migrationService ?? DataMigrationService(context: context)).getLocalDataStats()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(stats.sorted(by: { $0.key < $1.key }), id: \.key) { key, count in
                        VStack(spacing: 4) {
                            Text("\(count)")
                                .font(.title3.bold())
                                .foregroundStyle(.tint)
                            Text(key)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)))
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("当前本地数据档案")
            } footer: {
                Text("所有数据均保存在本机离线数据库中。利用 PIN 码加密导出包可安全跨手机迁移。")
            }

            // 2. 全量备份与迁移导出 (强制 PIN 码保护)
            Section {
                Button {
                    Haptic.impact(style: .medium)
                    showSetPinSheet = true
                } label: {
                    Label("设置 PIN 码并生成迁移备份", systemImage: "lock.shield.fill")
                        .font(.body.weight(.medium))
                }

                if let exportSuccessNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exportSuccessNotice)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("已采用 AES-256 密文存储，请牢记您的 PIN 码。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let exportTempURL {
                    ShareLink(item: exportTempURL, preview: SharePreview(exportFileName, icon: Image(systemName: "doc.zipper"))) {
                        Label("发送或保存加密备份到「文件」App", systemImage: "folder.badge.plus")
                            .foregroundStyle(.green)
                            .bold()
                    }
                }
            } header: {
                Text("安全迁移备份导出 (PIN 码加密)")
            } footer: {
                Text("🔒 安全机制：备份包含密码、证件等敏感数据，必须设置 PIN 码进行 AES-256 强加密。在新手机上恢复时必须输入相同的 PIN 码方可解锁。")
            }

            // 3. 从备份还原 (新手机恢复)
            Section {
                Button {
                    Haptic.impact(style: .light)
                    showFileImporter = true
                } label: {
                    Label("选择备份文件 (.json)", systemImage: "square.and.arrow.down.fill")
                }

                if let summary = inspectionSummary, let package = pendingPackage {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("已读取备份包")
                                .font(.headline)
                            Spacer()
                            if summary.isEncryptedWithPIN {
                                Label("PIN 验证通过", systemImage: "checkmark.shield.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.green.opacity(0.12)))
                            }
                            Text(summary.deviceModel)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.secondary.opacity(0.15)))
                        }

                        Text("导出时间：\(summary.exportedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Text("包含数据：共 \(summary.totalItems) 条")
                            .font(.subheadline.bold())
                        Text("• 待办: \(summary.todoCount) | 续费: \(summary.subscriptionCount) | 临期: \(summary.itemExpiryCount)")
                            .font(.caption)
                        Text("• 纪念日: \(summary.anniversaryCount) | 密码: \(summary.passwordCount) | 家务: \(summary.habitCount)")
                            .font(.caption)
                        Text("• 服药: \(summary.medicationCount) | 地点: \(summary.placeCount) | 流量: \(summary.usageRecordCount)")
                            .font(.caption)
                        Text("• 记账: \(summary.expenseCount) | 证件: \(summary.documentCount) | 防丢: \(summary.departureItemCount)")
                            .font(.caption)

                        Divider()

                        Picker("还原模式", selection: $selectedStrategy) {
                            ForEach(RestoreStrategy.allCases) { strategy in
                                Text(strategy.rawValue).tag(strategy)
                            }
                        }
                        .pickerStyle(.menu)

                        Button {
                            performRestore(package: package)
                        } label: {
                            HStack {
                                Spacer()
                                if isRestoring {
                                    ProgressView().padding(.trailing, 4)
                                }
                                Text("立即执行还原")
                                    .bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(selectedStrategy == .overwrite ? .red : .blue)
                        .disabled(isRestoring)
                    }
                    .padding(.vertical, 4)
                }

                if let restoreResultText {
                    Text(restoreResultText)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("从备份文件还原 (新手机恢复)")
            } footer: {
                Text("导入加密迁移文件后，系统将要求输入原设备导出的 PIN 码以完成解锁。")
            }

            // 4. 批量文本 / CSV 快速导入
            Section("批量快速录入 (CSV / 文本)") {
                Picker("录入类别", selection: $batchType) {
                    ForEach(BatchImportType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $batchText)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if batchText.isEmpty {
                            Text(batchType.placeholder)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                        batchText = UIPasteboard.general.string ?? ""
                    }
                    Spacer()
                    Button("确认批量录入") {
                        executeBatchImport()
                    }
                    .disabled(batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let batchResultNotice {
                    Text(batchResultNotice)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            }
        }
        .navigationTitle("数据备份与迁移")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .sheet(isPresented: $showSetPinSheet) {
            SetExportPinSheet(isPresented: $showSetPinSheet) { pin, hint in
                handleExportEncryptedBackup(pin: pin, hint: hint)
            }
        }
        .sheet(isPresented: $showUnlockPinSheet) {
            if let envelope = pendingEnvelope {
                UnlockBackupPinSheet(
                    isPresented: $showUnlockPinSheet,
                    envelope: envelope,
                    onUnlock: { pin in
                        handleUnlockBackup(envelope: envelope, pin: pin)
                    },
                    errorMessage: unlockErrorMessage
                )
            }
        }
        .onAppear {
            migrationService = DataMigrationService(context: context)
        }
    }

    // MARK: - 加密备份生成

    private func handleExportEncryptedBackup(pin: String, hint: String?) {
        guard let service = migrationService ?? DataMigrationService(context: context) as DataMigrationService? else { return }
        do {
            let (data, filename) = try service.exportEncryptedArchive(pin: pin, hint: hint)
            self.exportedData = data
            self.exportFileName = filename

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(filename)
            try data.write(to: fileURL)
            self.exportTempURL = fileURL
            self.exportSuccessNotice = "加密备份生成成功！"
            Haptic.success()
        } catch {
            self.exportSuccessNotice = "生成失败: \(error.localizedDescription)"
            Haptic.error()
        }
    }

    // MARK: - 导入文件解析与解锁

    private func handleFileImport(result: Result<[URL], Error>) {
        do {
            guard let selectedURL = try result.get().first else { return }
            guard selectedURL.startAccessingSecurityScopedResource() else {
                return
            }
            defer { selectedURL.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: selectedURL)
            let service = migrationService ?? DataMigrationService(context: context)
            let inspection = try service.inspectBackupFile(from: data)

            switch inspection {
            case .encrypted(let envelope):
                self.pendingEnvelope = envelope
                self.unlockErrorMessage = nil
                self.pendingPackage = nil
                self.inspectionSummary = nil
                self.restoreResultText = nil
                self.showUnlockPinSheet = true
                Haptic.impact(style: .medium)
            case .legacyPlaintext(let package, let summary):
                self.pendingPackage = package
                self.inspectionSummary = summary
                self.restoreResultText = nil
                Haptic.success()
            }
        } catch {
            self.restoreResultText = "解析备份文件失败：\(error.localizedDescription)"
            Haptic.error()
        }
    }

    private func handleUnlockBackup(envelope: EncryptedBackupEnvelope, pin: String) {
        guard let service = migrationService ?? DataMigrationService(context: context) as DataMigrationService? else { return }
        do {
            let (package, summary) = try service.unlockEncryptedArchive(envelope: envelope, pin: pin)
            self.pendingPackage = package
            self.inspectionSummary = summary
            self.restoreResultText = nil
            self.showUnlockPinSheet = false
            self.unlockErrorMessage = nil
            Haptic.success()
        } catch {
            self.unlockErrorMessage = error.localizedDescription
            Haptic.error()
        }
    }

    private func performRestore(package: BackupPackage) {
        guard let service = migrationService ?? DataMigrationService(context: context) as DataMigrationService? else { return }
        isRestoring = true
        do {
            let result = try service.restore(from: package, strategy: selectedStrategy)
            isRestoring = false
            self.restoreResultText = "✅ 还原完成！共恢复/合并 \(result.restoredCount) 条记录。\n" + result.details.joined(separator: "，")
            self.pendingPackage = nil
            self.inspectionSummary = nil
            Haptic.success()
        } catch {
            isRestoring = false
            self.restoreResultText = "❌ 还原失败: \(error.localizedDescription)"
            Haptic.error()
        }
    }

    // MARK: - 批量导入

    private func executeBatchImport() {
        guard let service = migrationService ?? DataMigrationService(context: context) as DataMigrationService? else { return }
        let count: Int
        switch batchType {
        case .anniversary:
            count = service.batchImportAnniversaries(text: batchText)
            batchResultNotice = "✅ 成功批量添加 \(count) 个纪念日/生日档案"
        case .password:
            count = service.batchImportPasswords(text: batchText)
            batchResultNotice = "✅ 成功批量登记 \(count) 个账号密码凭据"
        case .todo:
            count = service.batchImportTodos(text: batchText)
            batchResultNotice = "✅ 成功批量创建 \(count) 条待办事项"
        }
        batchText = ""
        Haptic.success()
    }
}

// MARK: - 设置导出 PIN 码弹窗

struct SetExportPinSheet: View {
    @Binding var isPresented: Bool
    let onConfirm: (String, String?) -> Void

    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var hint: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("设置迁移 PIN 码")
                                    .font(.headline)
                                Text("端到端 AES-256 加密保护")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("为了保护您的密码保险箱、重要证件、记账及防丢清单等隐私数据，迁移备份必须设置 PIN 码。新手机导入时必须输入相同的 PIN 码解锁。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("设置 PIN 码 (4 - 16 位)") {
                    SecureField("输入 PIN 码 (如 6 位数字)", text: $pin)
                        .keyboardType(.asciiCapableNumberPad)
                    SecureField("再次确认 PIN 码", text: $confirmPin)
                        .keyboardType(.asciiCapableNumberPad)
                }

                Section("密码提示 (选填)") {
                    TextField("例如：常用卡号后四位 / 某个特定年份", text: $hint)
                        .font(.subheadline)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("安全备份加密")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定生成") {
                        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanConfirm = confirmPin.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleanPin.count < 4 {
                            errorMessage = "PIN 码长度不能少于 4 位"
                            Haptic.error()
                            return
                        }
                        if cleanPin != cleanConfirm {
                            errorMessage = "两次输入的 PIN 码不一致，请重新核对"
                            Haptic.error()
                            return
                        }
                        let finalHint = hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hint
                        onConfirm(cleanPin, finalHint)
                        isPresented = false
                    }
                    .bold()
                    .disabled(pin.isEmpty || confirmPin.isEmpty)
                }
            }
        }
    }
}

// MARK: - 解锁备份 PIN 码弹窗

struct UnlockBackupPinSheet: View {
    @Binding var isPresented: Bool
    let envelope: EncryptedBackupEnvelope
    let onUnlock: (String) -> Void
    var errorMessage: String?

    @State private var pin: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("此备份文件已加密")
                                    .font(.headline)
                                Text("来自 \(envelope.deviceModel) · \(envelope.exportedAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let hint = envelope.hint, !hint.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.yellow)
                                Text("PIN 提示：\(hint)")
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
                        }

                        Text("请输入在原设备导出迁移数据时所设置的 PIN 码以完成解锁。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("输入解锁 PIN 码") {
                    SecureField("请输入 PIN 码", text: $pin)
                        .keyboardType(.asciiCapableNumberPad)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("解锁迁移备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁并读取") {
                        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanPin.isEmpty else { return }
                        onUnlock(cleanPin)
                    }
                    .bold()
                    .disabled(pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
