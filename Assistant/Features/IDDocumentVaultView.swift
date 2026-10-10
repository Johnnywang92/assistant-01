import PhotosUI
import SwiftData
import SwiftUI

/// 重要证件与照片保险箱主视图
struct IDDocumentVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \IDDocumentItem.createdAt, order: .reverse) private var documents: [IDDocumentItem]
    @StateObject private var auth = BiometricAuthManager.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared

    @State private var showingAddSheet = false
    @State private var selectedDocumentForDetail: IDDocumentItem?
    @State private var searchText = ""
    @State private var copiedFeedback = false

    private var filteredDocuments: [IDDocumentItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return documents
        }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.holderName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.documentNumber?.contains(searchText) ?? false) ||
            $0.type.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if auth.isUnlocked {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .navigationTitle("重要证件保险箱")
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
        .sheet(isPresented: $showingAddSheet) {
            AddIDDocumentSheet()
        }
        .sheet(item: $selectedDocumentForDetail) { doc in
            IDDocumentDetailView(document: doc)
        }
        .onAppear {
            if !auth.isUnlocked {
                auth.authenticate()
            }
        }
        .overlay(alignment: .bottom) {
            if copiedFeedback {
                Text("已复制证件号码到剪贴板")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 解锁后内容

    private var unlockedContent: some View {
        List {
            // 隐私安全背书横幅
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "shield.checkerboard")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("完全离线私有加密")
                            .font(.subheadline.bold())
                        Text("证件照片存入本设备独立沙盒中，绝不上云。支持正面与反面双页归档，办事填表随时一键复制号码。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // 证件列表
            Section("我的证件档案 (\(documents.count))") {
                if documents.isEmpty {
                    ContentUnavailableView(
                        "暂无证件记录",
                        systemImage: "person.text.rectangle",
                        description: Text("点击右上角 + 录入身份证、护照、驾照等证件正反面照片")
                    )
                } else if filteredDocuments.isEmpty {
                    Text("未找到匹配的证件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredDocuments) { doc in
                        IDDocumentCard(document: doc, onCopyNumber: triggerCopyFeedback) {
                            selectedDocumentForDetail = doc
                        }
                    }
                    .onDelete(perform: deleteDocuments)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .themedRow()
        .searchable(text: $searchText, prompt: "搜索证件名称、持有人或号码")
    }

    // MARK: - 锁定状态

    private var lockedContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text("证件保险箱已锁定")
                .font(.title3.bold())

            Text("为保护身份证、护照等敏感个人隐私与照片安全，需通过 Face ID / 密码验证后方可查看。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let err = auth.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                auth.authenticate()
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

    private func triggerCopyFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { copiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedFeedback = false }
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = filteredDocuments[index]
            IDPhotoStorage.deleteImage(fileName: doc.frontImageFileName)
            IDPhotoStorage.deleteImage(fileName: doc.backImageFileName)
            context.delete(doc)
        }
        try? context.save()
    }
}

// MARK: - 证件卡片行

struct IDDocumentCard: View {
    let document: IDDocumentItem
    let onCopyNumber: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：类型图标、标题、持有人、有效期状态
            HStack(alignment: .center) {
                Label(document.title, systemImage: document.type.icon)
                    .font(.headline)

                if let holder = document.holderName, !holder.isEmpty {
                    Text(holder)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                }

                Spacer()

                if document.isPermanent {
                    Text("长期有效")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if document.isExpired {
                    Text("已过期")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                } else if document.isExpiringSoon {
                    Text("即将过期")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                } else if let days = document.daysUntilExpiry {
                    Text("剩余 \(days) 天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 号码行（支持一键复制）
            if let num = document.documentNumber, !num.isEmpty {
                HStack {
                    Text(document.maskedNumber)
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = num
                        onCopyNumber()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("复制号码")
                        }
                        .font(.caption)
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemGroupedBackground)))
            }

            // 照片双格预览槽位
            HStack(spacing: 12) {
                photoSlotPreview(
                    label: document.type.frontSlotLabel,
                    fileName: document.frontImageFileName
                )
                photoSlotPreview(
                    label: document.type.backSlotLabel,
                    fileName: document.backImageFileName
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .themedRow()
    }

    @ViewBuilder
    private func photoSlotPreview(label: String, fileName: String?) -> some View {
        let image = IDPhotoStorage.loadImage(fileName: fileName)
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 70)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "photo.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("未添加")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 证件详情与高清查看视图

struct IDDocumentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let document: IDDocumentItem

    @State private var showingEditSheet = false
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("证件类型", value: document.type.rawValue)
                    if let holder = document.holderName, !holder.isEmpty {
                        LabeledContent("持有人姓名", value: holder)
                    }
                    if let num = document.documentNumber, !num.isEmpty {
                        LabeledContent("证件号码") {
                            HStack {
                                Text(num).font(.system(.body, design: .monospaced).bold())
                                Button {
                                    UIPasteboard.general.string = num
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.footnote)
                                }
                            }
                        }
                    }
                    if document.isPermanent {
                        LabeledContent("有效期", value: "长期有效")
                    } else if let date = document.expiryDate {
                        LabeledContent("到期日期") {
                            Text(date, format: .dateTime.year().month().day())
                        }
                    }
                    if let notes = document.notes, !notes.isEmpty {
                        LabeledContent("补充备注", value: notes)
                    }
                } header: {
                    Text("证件基本资料")
                }

                // 正反面照片高清卡片
                Section(document.type.frontSlotLabel) {
                    if let front = IDPhotoStorage.loadImage(fileName: document.frontImageFileName) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(uiImage: front)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(10)
                                .onTapGesture { previewImage = front }

                            HStack {
                                Text("轻点放大预览")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ShareLink(item: Image(uiImage: front), preview: SharePreview(document.title, image: Image(uiImage: front))) {
                                    Label("分享/导出", systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("未录入该面照片").foregroundStyle(.secondary)
                    }
                }

                Section(document.type.backSlotLabel) {
                    if let back = IDPhotoStorage.loadImage(fileName: document.backImageFileName) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(uiImage: back)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(10)
                                .onTapGesture { previewImage = back }

                            HStack {
                                Text("轻点放大预览")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ShareLink(item: Image(uiImage: back), preview: SharePreview(document.title, image: Image(uiImage: back))) {
                                    Label("分享/导出", systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("未录入该面照片").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { showingEditSheet = true }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                AddIDDocumentSheet(editingItem: document)
            }
            .fullScreenCover(item: Binding<IdentifiableImage?>(
                get: { previewImage.map { IdentifiableImage(image: $0) } },
                set: { previewImage = $0?.image }
            )) { item in
                FullScreenImageViewer(image: item.image) {
                    previewImage = nil
                }
            }
        }
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - 全屏大图查看器

struct FullScreenImageViewer: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in
                            scale = lastScale * val
                        }
                        .onEnded { _ in
                            if scale < 1.0 { scale = 1.0 }
                            lastScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = scale > 1.0 ? 1.0 : 2.5
                        lastScale = scale
                    }
                }

            VStack {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("证件原图", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()
                Spacer()
            }
        }
    }
}

// MARK: - 添加 / 编辑证件表单

struct AddIDDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var editingItem: IDDocumentItem?

    @State private var selectedType: IDDocumentType = .idCard
    @State private var title: String = ""
    @State private var holderName: String = ""
    @State private var documentNumber: String = ""
    @State private var isPermanent: Bool = false
    @State private var expiryDate: Date = Calendar.current.date(byAdding: .year, value: 10, to: .now) ?? .now
    @State private var notes: String = ""

    // 照片上传与预览状态
    @State private var frontItem: PhotosPickerItem?
    @State private var frontImage: UIImage?
    @State private var backItem: PhotosPickerItem?
    @State private var backImage: UIImage?

    @State private var showingCameraForFront = false
    @State private var showingCameraForBack = false

    var body: some View {
        NavigationStack {
            Form {
                Section("证件类型与名称") {
                    Picker("证件类型", selection: $selectedType) {
                        ForEach(IDDocumentType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .onChange(of: selectedType) { _, newType in
                        if title.isEmpty || IDDocumentType.allCases.map(\.rawValue).contains(title) {
                            title = newType.rawValue
                        }
                    }

                    TextField("证件别名（如：本人身份证）", text: $title)
                    TextField("持有人姓名（可选）", text: $holderName)
                }

                Section("证件号码") {
                    TextField("输入号码（支持一键复制）", text: $documentNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }

                // 照片采集槽位
                Section("证件照片存档（完全离线保存在本地沙盒）") {
                    // 正面
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedType.frontSlotLabel).font(.caption.bold())
                        if let front = frontImage {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: front)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 180)
                                    .cornerRadius(8)

                                Button {
                                    frontImage = nil
                                    frontItem = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white, .red)
                                }
                                .padding(6)
                            }
                        } else {
                            PhotosPicker(selection: $frontItem, matching: .images) {
                                Label("从相册选取 \(selectedType.frontSlotLabel)", systemImage: "photo.badge.plus")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    // 反面
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedType.backSlotLabel).font(.caption.bold())
                        if let back = backImage {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: back)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 180)
                                    .cornerRadius(8)

                                Button {
                                    backImage = nil
                                    backItem = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white, .red)
                                }
                                .padding(6)
                            }
                        } else {
                            PhotosPicker(selection: $backItem, matching: .images) {
                                Label("从相册选取 \(selectedType.backSlotLabel)", systemImage: "photo.badge.plus")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("证件有效期") {
                    Toggle("长期有效", isOn: $isPermanent)
                    if !isPermanent {
                        DatePicker("截止日期", selection: $expiryDate, displayedComponents: .date)
                    }
                }

                Section("补充备忘") {
                    TextField("签发机关、用途限制等备注信息", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(editingItem == nil ? "录入重要证件" : "编辑证件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveDocument() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExistingData() }
            .onChange(of: frontItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        frontImage = uiImage
                    }
                }
            }
            .onChange(of: backItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        backImage = uiImage
                    }
                }
            }
        }
    }

    private func loadExistingData() {
        guard let item = editingItem else {
            title = selectedType.rawValue
            return
        }
        selectedType = item.type
        title = item.title
        holderName = item.holderName ?? ""
        documentNumber = item.documentNumber ?? ""
        isPermanent = item.isPermanent
        if let d = item.expiryDate { expiryDate = d }
        notes = item.notes ?? ""
        frontImage = IDPhotoStorage.loadImage(fileName: item.frontImageFileName)
        backImage = IDPhotoStorage.loadImage(fileName: item.backImageFileName)
    }

    private func saveDocument() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        // 保存正面照片到沙盒
        var frontFileName = editingItem?.frontImageFileName
        if let front = frontImage {
            if frontFileName == nil || front != IDPhotoStorage.loadImage(fileName: frontFileName) {
                IDPhotoStorage.deleteImage(fileName: frontFileName)
                frontFileName = IDPhotoStorage.saveImage(front)
            }
        } else {
            IDPhotoStorage.deleteImage(fileName: frontFileName)
            frontFileName = nil
        }

        // 保存反面照片到沙盒
        var backFileName = editingItem?.backImageFileName
        if let back = backImage {
            if backFileName == nil || back != IDPhotoStorage.loadImage(fileName: backFileName) {
                IDPhotoStorage.deleteImage(fileName: backFileName)
                backFileName = IDPhotoStorage.saveImage(back)
            }
        } else {
            IDPhotoStorage.deleteImage(fileName: backFileName)
            backFileName = nil
        }

        if let existing = editingItem {
            existing.title = trimmedTitle
            existing.type = selectedType
            existing.holderName = holderName.isEmpty ? nil : holderName
            existing.documentNumber = documentNumber.isEmpty ? nil : documentNumber
            existing.isPermanent = isPermanent
            existing.expiryDate = isPermanent ? nil : expiryDate
            existing.notes = notes.isEmpty ? nil : notes
            existing.frontImageFileName = frontFileName
            existing.backImageFileName = backFileName
            existing.updatedAt = .now
        } else {
            let newDoc = IDDocumentItem(
                title: trimmedTitle,
                type: selectedType,
                holderName: holderName.isEmpty ? nil : holderName,
                documentNumber: documentNumber.isEmpty ? nil : documentNumber,
                expiryDate: expiryDate,
                isPermanent: isPermanent,
                frontImageFileName: frontFileName,
                backImageFileName: backFileName,
                notes: notes.isEmpty ? nil : notes
            )
            context.insert(newDoc)
        }

        try? context.save()
        dismiss()
    }
}
