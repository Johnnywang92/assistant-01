import AssistantCore
import SwiftData
import SwiftUI

/// NAS 与私有云盘 WebDAV 同步配置与管理视图
struct WebDAVSyncView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var syncService = WebDAVSyncService.shared

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var passwordInput: String = ""
    @State private var remoteDirectory: String = "assistant-backup"
    @State private var autoSyncEnabled: Bool = false

    @State private var isTestingConnection: Bool = false
    @State private var testResultText: String?
    @State private var testIsSuccess: Bool = false

    @State private var isUploading: Bool = false
    @State private var uploadResultText: String?

    @State private var remoteBackups: [WebDAVFileItem] = []
    @State private var isLoadingRemoteList: Bool = false
    @State private var selectedItemForRestore: WebDAVFileItem?
    @State private var restorePinInput: String = ""
    @State private var isRestoring: Bool = false
    @State private var restoreSuccessSummary: String?

    @State private var uploadPinInput: String = ""
    @State private var showUploadPinSheet: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            // MARK: - 安全承诺与机制说明
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title3)
                            .foregroundStyle(AppColor.success)
                        Text("端到端强加密备份")
                            .font(.subheadline.bold())
                    }
                    Text("所有数据在上传前均在 iPhone 本地经过 PBKDF2（310,000轮）与 AES-256-GCM 随机盐加密封装。即使 NAS 或云盘开放公网访问，备份文件也是无法被破解的密文。")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(.vertical, 4)
            }

            // MARK: - 服务器连接配置
            Section(header: Text("WebDAV 服务器连接设置")) {
                TextField("服务器地址（如 https://nas.lan:5006/dav）", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("用户名", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField(syncService.hasPassword ? "密码已安全保存在钥匙串（留空保持不变）" : "密码", text: $passwordInput)

                TextField("备份存储子目录", text: $remoteDirectory)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    saveAndTestConnection()
                } label: {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTestingConnection ? "正在连接 NAS / 云盘..." : "保存并测试连接")
                            .bold()
                    }
                }
                .disabled(serverURL.isEmpty || username.isEmpty || isTestingConnection)

                if let result = testResultText {
                    HStack(spacing: 6) {
                        Image(systemName: testIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testIsSuccess ? AppColor.success : AppColor.danger)
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testIsSuccess ? AppColor.success : AppColor.danger)
                    }
                }
            }

            // MARK: - 同步与备份操作
            Section(header: Text("备份与自动同步")) {
                Toggle("启用后台静默自动备份", isOn: $autoSyncEnabled)
                    .onChange(of: autoSyncEnabled) { _, newValue in
                        var updated = syncService.config
                        updated.autoSyncEnabled = newValue
                        syncService.saveConfig(updated)
                    }

                if let lastDate = syncService.config.lastSyncDate {
                    HStack {
                        Text("上次同步时间")
                        Spacer()
                        Text(lastDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                if let status = syncService.config.lastSyncStatus {
                    HStack {
                        Text("上次同步状态")
                        Spacer()
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                Button {
                    showUploadPinSheet = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("立即打包并上传至 NAS / 云盘")
                            .bold()
                    }
                }
                .disabled(!syncService.config.isConfigured || !syncService.hasPassword || isUploading)
            }

            // MARK: - 远端历史备份列表
            Section(header: HStack {
                Text("NAS / 云盘上的历史备份")
                Spacer()
                Button {
                    loadRemoteBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoadingRemoteList || !syncService.config.isConfigured)
            }) {
                if isLoadingRemoteList {
                    HStack {
                        Spacer()
                        ProgressView("正在从 NAS 获取文件列表...")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if remoteBackups.isEmpty {
                    Text("远端备份目录下暂无 .assistantbackup 历史备份文件。")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                } else {
                    ForEach(remoteBackups) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "doc.zipper")
                                    .foregroundStyle(AppColor.info)
                                Text(item.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Spacer()
                                Text(item.formattedSize)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppColor.secondaryText)
                            }

                            if let mod = item.lastModified {
                                Text("修改时间: \(mod.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    selectedItemForRestore = item
                                } label: {
                                    Label("下载并恢复", systemImage: "arrow.down.circle")
                                        .font(.caption.bold())
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    deleteRemoteFile(item)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("NAS 与私有云同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let current = syncService.config
            serverURL = current.serverURL
            username = current.username
            remoteDirectory = current.remoteDirectory
            autoSyncEnabled = current.autoSyncEnabled
            if current.isConfigured && syncService.hasPassword {
                loadRemoteBackups()
            }
        }
        // MARK: - 立即上传输入口令弹窗
        .sheet(isPresented: $showUploadPinSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("设置本次备份文件的加密口令")) {
                        SecureField("请输入 8~64 位加密口令", text: $uploadPinInput)
                        Text("该口令用于派生 AES-256 密钥。换机或还原该文件时需输入此口令，请务必妥善记录。")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Button {
                        showUploadPinSheet = false
                        performUpload(pin: uploadPinInput)
                    } label: {
                        Text("开始加密并上传")
                            .bold()
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(uploadPinInput.count < 8)
                }
                .navigationTitle("备份上传验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showUploadPinSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        // MARK: - 下载并还原弹窗
        .sheet(item: $selectedItemForRestore) { item in
            NavigationStack {
                Form {
                    Section(header: Text("还原选中的历史备份")) {
                        Text("文件名: \(item.name)")
                            .font(.subheadline)
                        Text("大小: \(item.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        SecureField("请输入此备份的解密口令", text: $restorePinInput)
                    }

                    Section(header: Text("还原策略")) {
                        Button {
                            performRestore(item: item, strategy: .merge)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("智能合并还原（推荐）")
                                    .bold()
                                Text("将备份中的数据去重并入当前应用，不删除现有新数据。")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }
                        .disabled(restorePinInput.isEmpty || isRestoring)

                        Button(role: .destructive) {
                            performRestore(item: item, strategy: .overwrite)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("全量覆盖还原")
                                    .bold()
                                Text("完全使用该备份替换当前设备全部数据。")
                                    .font(.caption2)
                            }
                        }
                        .disabled(restorePinInput.isEmpty || isRestoring)
                    }

                    if isRestoring {
                        HStack {
                            Spacer()
                            ProgressView("正在从 NAS 下载并解密还原...")
                            Spacer()
                        }
                    }
                }
                .navigationTitle("从 NAS 还原数据")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { selectedItemForRestore = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("错误提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 交互操作逻辑

    private func saveAndTestConnection() {
        var newConfig = syncService.config
        newConfig.serverURL = serverURL
        newConfig.username = username
        newConfig.remoteDirectory = remoteDirectory
        syncService.saveConfig(newConfig, password: passwordInput.isEmpty ? nil : passwordInput)

        isTestingConnection = true
        testResultText = nil

        Task {
            do {
                let msg = try await syncService.testConnection()
                testIsSuccess = true
                testResultText = msg
                loadRemoteBackups()
            } catch {
                testIsSuccess = false
                testResultText = error.localizedDescription
            }
            isTestingConnection = false
        }
    }

    private func performUpload(pin: String) {
        isUploading = true
        Task {
            do {
                let result = try await syncService.uploadBackup(pin: pin, hint: "手动上传至NAS", context: context)
                testResultText = "备份上传成功！文件: \(result.filename) (\(result.formattedSize))"
                testIsSuccess = true
                loadRemoteBackups()
            } catch {
                errorMessage = "上传失败: \(error.localizedDescription)"
            }
            isUploading = false
        }
    }

    private func loadRemoteBackups() {
        isLoadingRemoteList = true
        Task {
            do {
                let list = try await syncService.listRemoteBackups()
                remoteBackups = list
            } catch {
                // 不阻断界面，仅展示为空
                remoteBackups = []
            }
            isLoadingRemoteList = false
        }
    }

    private func performRestore(item: WebDAVFileItem, strategy: RestoreStrategy) {
        isRestoring = true
        Task {
            do {
                let downloadedData = try await syncService.downloadBackup(item: item)
                let migrationService = DataMigrationService(context: context)
                let inspection = try migrationService.inspectBackupFile(from: downloadedData)

                switch inspection {
                case .encrypted(let envelope):
                    let unlocked = try migrationService.unlockEncryptedArchive(envelope: envelope, pin: restorePinInput)
                    _ = try migrationService.restore(from: unlocked.package, strategy: strategy)
                case .legacyPlaintext(let package, _):
                    _ = try migrationService.restore(from: package, strategy: strategy)
                }

                selectedItemForRestore = nil
                restorePinInput = ""
                testResultText = "从 NAS 成功恢复备份数据！🎉"
                testIsSuccess = true
            } catch {
                errorMessage = "恢复失败: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private func deleteRemoteFile(_ item: WebDAVFileItem) {
        Task {
            do {
                try await syncService.deleteRemoteBackup(item: item)
                loadRemoteBackups()
            } catch {
                errorMessage = "删除远端文件失败: \(error.localizedDescription)"
            }
        }
    }
}
