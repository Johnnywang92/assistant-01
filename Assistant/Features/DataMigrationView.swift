import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 数据备份、迁移与批量导入视图
struct DataMigrationView: View {
    @Environment(\.modelContext) private var context
    @State private var migrationService: DataMigrationService?

    // 导出状态
    @State private var isExporting = false
    @State private var exportedData: Data?
    @State private var exportFileName: String = "Assistant_Backup.json"
    @State private var showExportShare = false
    @State private var exportTempURL: URL?

    // 导入状态
    @State private var showFileImporter = false
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
                Text("所有数据均保存在本机离线数据库中。利用导出包可跨手机迁移或进行安全备份。")
            }

            // 2. 全量备份与迁移导出
            Section("数据备份与导出 (JSON)") {
                Button {
                    generateBackupFile()
                } label: {
                    Label("生成全量备份文件", systemImage: "square.and.arrow.up.fill")
                }

                if let exportTempURL {
                    ShareLink(item: exportTempURL, preview: SharePreview(exportFileName, icon: Image(systemName: "doc.zipper"))) {
                        Label("发送或保存到「文件」App", systemImage: "folder.badge.plus")
                            .foregroundStyle(.green)
                    }
                }
            }

            // 3. 从备份还原
            Section("从备份文件还原 (JSON)") {
                Button {
                    showFileImporter = true
                } label: {
                    Label("选择备份文件 (.json)", systemImage: "square.and.arrow.down.fill")
                }

                if let summary = inspectionSummary, let package = pendingPackage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("已读取备份包")
                                .font(.headline)
                            Spacer()
                            Text(summary.deviceModel)
                                .font(.caption)
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
        .onAppear {
            migrationService = DataMigrationService(context: context)
        }
    }

    // MARK: - 备份生成

    private func generateBackupFile() {
        guard let service = migrationService ?? DataMigrationService(context: context) as DataMigrationService? else { return }
        do {
            let (data, filename) = try service.exportArchive()
            self.exportedData = data
            self.exportFileName = filename

            // 写入临时缓存以便通过 ShareLink 分享或保存
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(filename)
            try data.write(to: fileURL)
            self.exportTempURL = fileURL
            self.showExportShare = true
        } catch {
            print("导出失败: \(error)")
        }
    }

    // MARK: - 导入文件解析

    private func handleFileImport(result: Result<[URL], Error>) {
        do {
            guard let selectedURL = try result.get().first else { return }
            guard selectedURL.startAccessingSecurityScopedResource() else {
                return
            }
            defer { selectedURL.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: selectedURL)
            let service = migrationService ?? DataMigrationService(context: context)
            let (package, summary) = try service.inspectArchive(from: data)
            self.pendingPackage = package
            self.inspectionSummary = summary
            self.restoreResultText = nil
        } catch {
            self.restoreResultText = "解析备份文件失败：\(error.localizedDescription)"
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
        } catch {
            isRestoring = false
            self.restoreResultText = "❌ 还原失败: \(error.localizedDescription)"
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
    }
}
