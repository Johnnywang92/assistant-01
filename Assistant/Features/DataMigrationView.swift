import AssistantCore
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

    // 备份/迁移门禁 PIN（首次冷启动已强制设置；每次进入本屏需重新解锁）
    @StateObject private var pinGate = MigrationPinManager.shared
    @State private var isMigrationUnlocked = false
    @State private var showUnlockGate = false
    @State private var showChangePinSheet = false
    @State private var gatePinChangeNotice: String?

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
                        .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(Color(.secondarySystemGroupedBackground)))
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

            // 2.5 门禁 PIN 修改：仅把守本屏入口，与各备份文件的加密 PIN 相互独立
            Section {
                Button {
                    Haptic.impact(style: .light)
                    showChangePinSheet = true
                } label: {
                    Label("修改门禁 PIN 码", systemImage: "key.fill")
                        .font(.body.weight(.medium))
                }

                if let gatePinChangeNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(gatePinChangeNotice)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("门禁 PIN")
            } footer: {
                Text("门禁 PIN 只锁定本屏入口，可随时修改；它与各备份文件自身的加密 PIN 是两回事，修改门禁 PIN 不影响已导出备份的解密。")
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
                        Text("• 记账: \(summary.expenseCount) | 证件: \(summary.documentCount) | 防丢: \(summary.departureItemCount) | 备忘: \(summary.voiceMemoCount)")
                            .font(.caption)
                        Text("• 爱车: \(summary.vehicleCount) | 收纳: \(summary.storedItemCount) | 对话: \(summary.dialogueCount)")
                            .font(.caption)
                        Text("• 原始消息: \(summary.rawMessageCount) | 位置采样: \(summary.locationSampleCount)")
                            .font(.caption)
                        if summary.skillPathCount > 0 || summary.practiceLogCount > 0 {
                            Text("• 学习路径: \(summary.skillPathCount) 条 | 阶段: \(summary.skillStageCount) | 打卡: \(summary.practiceLogCount) 次")
                                .font(.caption)
                        }
                        if summary.petCount > 0 || summary.reminderActionCount > 0 {
                            Text("• 宠物: \(summary.petCount) | 提醒动作: \(summary.reminderActionCount)")
                                .font(.caption)
                        }
                        if summary.childCount > 0 || summary.childGrowthCount > 0 || summary.childMilestoneCount > 0 || summary.childHealthVisitCount > 0 || summary.childVaccinationCount > 0 {
                            Text("• 宝贝: \(summary.childCount) | 成长: \(summary.childGrowthCount) | 里程碑: \(summary.childMilestoneCount) | 就医: \(summary.childHealthVisitCount) | 疫苗: \(summary.childVaccinationCount)")
                                .font(.caption)
                        }
                        if summary.lifeEventProjectCount > 0 || summary.lifeEventStageCount > 0 || summary.lifeEventTaskCount > 0 || summary.lifeEventPersonCount > 0 || summary.lifeEventExpenseCount > 0 || summary.lifeEventGuestCount > 0 {
                            Text("• 人生大事: \(summary.lifeEventProjectCount) | 阶段: \(summary.lifeEventStageCount) | 任务: \(summary.lifeEventTaskCount) | 人员: \(summary.lifeEventPersonCount) | 支出: \(summary.lifeEventExpenseCount) | 宾客: \(summary.lifeEventGuestCount)")
                                .font(.caption)
                        }
                        if summary.omniboxTransactionCount > 0 {
                            Text("• 投喂事务: \(summary.omniboxTransactionCount) 笔")
                                .font(.caption)
                        }
                        if summary.settingsKeyCount > 0 {
                            Text("• 偏好设置: \(summary.settingsKeyCount) 项（名称/语言/背景/预算/报告推送等）")
                                .font(.caption)
                        }

                        Divider()

                        Picker("还原模式", selection: $selectedStrategy) {
                            ForEach(RestoreStrategy.allCases) { strategy in
                                Text(L10n.tr(strategy.rawValue)).tag(strategy)
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
                        Text(L10n.tr(type.rawValue)).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $batchText)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if batchText.isEmpty {
                            Text(L10n.tr(batchType.placeholder))
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
        .overlay {
            if pinGate.isConfigured && !isMigrationUnlocked {
                migrationLockCover
            }
        }
        .sheet(isPresented: $showUnlockGate) {
            MigrationUnlockPinSheet(isPresented: $showUnlockGate, onSuccess: {
                isMigrationUnlocked = true
                Haptic.success()
            })
        }
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
        .sheet(isPresented: $showChangePinSheet) {
            ChangeMigrationPinSheet(isPresented: $showChangePinSheet, onSuccess: {
                gatePinChangeNotice = "门禁 PIN 已修改，下次进入本页请用新 PIN 解锁。"
                Haptic.success()
            })
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
            // 每次进入本屏都重新上锁，需再次输入门禁 PIN
            isMigrationUnlocked = false
        }
    }

    /// 未解锁时覆盖整屏的门禁卡片：输入备份 PIN 后才能备份生成/数据迁移。
    private var migrationLockCover: some View {
        ZStack {
            Color(.systemBackground).opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("备份与迁移已锁定")
                    .font(.headline)
                Text("为防止他人随意导出或覆盖您的数据，\n生成备份与还原数据前需先输入备份 PIN 码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showUnlockGate = true
                } label: {
                    Label("输入 PIN 码解锁", systemImage: "lock.open")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)

                if let hint = pinGate.hint, !hint.isEmpty {
                    Text("提示：\(hint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("忘记 PIN 码？重置门禁", role: .destructive) {
                    // 重置仅清空本地门禁，不影响任何已导出备份（它们由各自的加密 PIN 保护）
                    pinGate.reset()
                }
                .font(.caption)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 20)
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
                throw CocoaError(.fileReadNoPermission)
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
        do {
            let imported: Int
            switch batchType {
            case .anniversary:
                let report = try service.batchImportAnniversaries(text: batchText)
                imported = report.imported
                batchResultNotice = Self.batchImportNotice("批量添加", unit: "个纪念日/生日档案", report: report)
            case .password:
                let report = try service.batchImportPasswords(text: batchText)
                imported = report.imported
                batchResultNotice = Self.batchImportNotice("批量登记", unit: "个账号密码凭据", report: report)
            case .todo:
                let count = try service.batchImportTodos(text: batchText)
                imported = count
                batchResultNotice = "✅ 成功批量创建 \(count) 条待办事项"
            }
            // 有条目落库才清空输入；全部被跳过时保留原文，方便用户按回执改那一行
            if imported > 0 { batchText = "" }
            if imported > 0 { Haptic.success() } else { Haptic.error() }
        } catch {
            batchResultNotice = "❌ 导入失败：\(error.localizedDescription)"
            Haptic.error()
        }
    }

    private static func batchImportNotice(_ verb: String, unit: String, report: BatchImportReport) -> String {
        var text = report.imported > 0
            ? "✅ 成功\(verb) \(report.imported) \(unit)"
            : "⚠️ 未导入任何记录"
        if !report.skipped.isEmpty {
            let shown = report.skipped.prefix(5).map { "第 \($0.line) 行：\($0.reason)" }.joined(separator: "；")
            let tail = report.skipped.count > 5 ? "；…等 \(report.skipped.count) 行" : ""
            text += "；跳过 \(report.skipped.count) 行（\(shown)\(tail)）"
        }
        return text
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

                Section("设置备份口令 (8 - 64 位)") {
                    SecureField("输入至少 8 位口令", text: $pin)
                        .keyboardType(.asciiCapable)
                    SecureField("再次确认 PIN 码", text: $confirmPin)
                        .keyboardType(.asciiCapable)
                }

                Section("密码提示 (选填)") {
                    TextField("仅填写自己看得懂的提示，不要写出完整口令", text: $hint)
                        .font(.subheadline)
                }

                if let errorMessage {
                    Section {
                        Text(L10n.tr(errorMessage))
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
                        if cleanPin.count < 8 || cleanPin.count > 64 {
                            errorMessage = "备份口令需为 8 到 64 位"
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
                            .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(Color.yellow.opacity(0.12)))
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
                        Text(L10n.tr(errorMessage))
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

// MARK: - 首次冷启动：强制设置备份门禁 PIN

/// 应用首次冷启动时遮在根视图之上、无法跳过的设置页；写入成功后 `isConfigured` 置 true，遮罩自动消失。
struct MigrationPinSetupView: View {
    @ObservedObject private var pinGate = MigrationPinManager.shared
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var hint = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("首次使用，请先设置备份 PIN 码", systemImage: "lock.shield.fill")
                        .font(.headline)
                    Text("此 PIN 码用于锁定“数据备份与迁移”入口：只有输入它，才能生成备份或还原数据。建议与备份加密口令区分记忆。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("安全设置")
                }

                Section("设置解锁 PIN（8–64 位）") {
                    SecureField("输入 PIN 码", text: $pin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("再次确认 PIN 码", text: $confirmPin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section("PIN 提示（选填，仅自己看得懂）") {
                    TextField("例如：妈妈的生日后两位…", text: $hint)
                }

                Section {
                    Text("🔒 PIN 码只在本机派生为校验值保存，不会上传、也不会写入备份；忘记时可在迁移页重置门禁（不影响已导出的加密备份）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("首次使用 · 安全设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成设置") {
                        submit()
                    }
                    .bold()
                    .disabled(pin.isEmpty || confirmPin.isEmpty)
                }
            }
        }
    }

    private func submit() {
        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanConfirm = confirmPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.count >= 8, cleanPin.count <= 64 else {
            errorMessage = "PIN 码长度需为 8–64 位，请重新输入。"
            return
        }
        guard cleanPin == cleanConfirm else {
            errorMessage = "两次输入的 PIN 码不一致，请确认。"
            return
        }
        do {
            try pinGate.setPin(cleanPin, hint: hint)
            Haptic.success()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            Haptic.error()
        }
    }
}

// MARK: - 进入迁移页时的解锁弹层

/// 输入已设置的门禁 PIN 解锁本次会话；校验交给 `MigrationPinManager`（PBKDF2 派生比对）。
struct MigrationUnlockPinSheet: View {
    @ObservedObject private var pinGate = MigrationPinManager.shared
    @Binding var isPresented: Bool
    let onSuccess: () -> Void

    @State private var pin = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("输入备份 PIN 码解锁", systemImage: "lock.open.fill")
                        .font(.headline)
                    if let hint = pinGate.hint, !hint.isEmpty {
                        Text("提示：\(hint)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    SecureField("PIN 码", text: $pin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("解锁备份与迁移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") {
                        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanPin.isEmpty else { return }
                        if pinGate.verify(cleanPin) {
                            isPresented = false
                            onSuccess()
                        } else {
                            errorMessage = "PIN 码不正确，请重试。"
                            Haptic.error()
                        }
                    }
                    .bold()
                    .disabled(pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 修改门禁 PIN（需先验证当前 PIN）

/// 校验当前门禁 PIN 后设置新 PIN，可同时更新提示；验错时旧 PIN 始终有效（`MigrationPinManager.changePin` 仅在校验通过后才写入）。
struct ChangeMigrationPinSheet: View {
    @ObservedObject private var pinGate = MigrationPinManager.shared
    @Binding var isPresented: Bool
    let onSuccess: () -> Void

    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var hint = ""
    @State private var errorMessage: String?

    init(isPresented: Binding<Bool>, onSuccess: @escaping () -> Void) {
        _isPresented = isPresented
        self.onSuccess = onSuccess
        // 预填既有提示，方便只改 PIN 不改提示
        _hint = State(initialValue: MigrationPinManager.shared.hint ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("验证当前 PIN 码") {
                    SecureField("输入 PIN 码", text: $currentPin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if let hint = pinGate.hint, !hint.isEmpty {
                        Text("提示：\(hint)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("设置新 PIN（8–64 位）") {
                    SecureField("输入新 PIN 码", text: $newPin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("再次确认新 PIN 码", text: $confirmPin)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section("PIN 提示（选填，仅自己看得懂）") {
                    TextField("例如：妈妈的生日后两位…", text: $hint)
                }

                Section {
                    Text("🔒 PIN 码只在本机派生为校验值保存，不会上传、也不会写入备份；忘记时可在迁移页重置门禁（不影响已导出的加密备份）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("修改门禁 PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        submit()
                    }
                    .bold()
                    .disabled(currentPin.isEmpty || newPin.isEmpty || confirmPin.isEmpty)
                }
            }
        }
    }

    private func submit() {
        let cleanCurrent = currentPin.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPin = newPin.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanConfirm = confirmPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.count >= 8, cleanPin.count <= 64 else {
            errorMessage = "PIN 码长度需为 8–64 位，请重新输入。"
            return
        }
        guard cleanPin == cleanConfirm else {
            errorMessage = "两次输入的 PIN 码不一致，请确认。"
            return
        }
        do {
            try pinGate.changePin(current: cleanCurrent, to: cleanPin, hint: hint)
            errorMessage = nil
            isPresented = false
            onSuccess()
        } catch {
            errorMessage = error.localizedDescription
            Haptic.error()
        }
    }
}
