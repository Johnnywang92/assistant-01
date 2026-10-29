import AssistantCore
import PhotosUI
import SwiftUI
import UIKit

/// 小票识别记账。支持相机拍摄，也支持一次选择多张照片，适合超长小票分段拍摄。
struct ReceiptScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var recognizedText = ""
    @State private var showingCamera = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // 可编辑与交互兜底状态
    @State private var hasParsed: Bool = false
    @State private var amountText: String = ""
    @State private var selectedCurrency: ExpenseCurrency = .cny
    @State private var titleText: String = ""
    @State private var selectedCategory: ExpenseCategory = .food
    @State private var selectedDate: Date = .now
    @State private var candidateAmounts: [Double] = []
    @State private var recognitionConfidence: Double = 1.0
    @State private var confidenceReason: String? = nil
    @State private var isShowingRawText: Bool = false

    let onSave: (ExpenseParseResult, String, Data?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("拍一张", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        PhotosPicker(selection: $selectedItems, maxSelectionCount: 20, matching: .images) {
                            Label("选择多张", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("小票较长时，请按顺序分段拍摄或选择多张照片。识别会合并所有页面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !images.isEmpty {
                    Section("已添加 \(images.count) 张") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 70, height: 92)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                guard images.indices.contains(index) else { return }
                                                images.remove(at: index)
                                                if images.isEmpty {
                                                    hasParsed = false
                                                    recognizedText = ""
                                                }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.white, .black.opacity(0.55))
                                            }
                                            .padding(3)
                                        }
                                }
                            }
                        }

                        Button {
                            Task { await recognizeReceipt() }
                        } label: {
                            HStack {
                                if isProcessing { ProgressView() }
                                Text(isProcessing ? "正在识别小票…" : (hasParsed ? "重新识别" : "识别并提取数据"))
                                Spacer()
                                Image(systemName: "text.viewfinder")
                            }
                        }
                        .disabled(isProcessing)
                    }
                }

                if hasParsed {
                    // 低置信度兜底警告横幅
                    if recognitionConfidence < 0.75 {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("识别置信度较低（\(Int(recognitionConfidence * 100))%）")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.orange)
                                }
                                if let reason = confidenceReason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("支持下方自由修改金额、分类或直接点选候选金额：")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 识别结果可编辑表单（全字段可调，支持候选金额快捷点选）
                    Section("核对记账数据") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("消费金额")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    ForEach(ExpenseCurrency.allCases) { cur in
                                        Button(cur.pickerLabel) {
                                            selectedCurrency = cur
                                            Haptic.selection()
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(selectedCurrency.flag)
                                        Text(selectedCurrency.symbol)
                                            .font(.subheadline.bold())
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                HStack(spacing: 2) {
                                    TextField("0.00", text: $amountText)
                                        .font(.title2.bold())
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(minWidth: 100)
                                }
                                if !amountText.isEmpty {
                                    Button {
                                        amountText = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if selectedCurrency != .cny,
                               let rawVal = Double(amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
                               rawVal > 0 {
                                HStack {
                                    Text(selectedCurrency.rateDisplayString())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "折合人民币 ≈ ¥%.2f", selectedCurrency.convertToCNY(rawVal)))
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                }
                            }

                            if !candidateAmounts.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("备选提取金额（点击快捷填入）：")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(candidateAmounts, id: \.self) { cand in
                                                let candStr = String(format: "%.2f", cand)
                                                Button {
                                                    amountText = candStr
                                                    Haptic.selection()
                                                } label: {
                                                    Text("\(selectedCurrency.symbol)\(candStr)")
                                                        .font(.caption.monospaced().bold())
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(amountText == candStr ? Color.accentColor : Color(.tertiarySystemFill))
                                                        .foregroundStyle(amountText == candStr ? Color.white : Color.primary)
                                                        .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }

                        HStack {
                            Text("项目名称")
                                .foregroundStyle(.secondary)
                            TextField("商户或消费项目（如：麦当劳早餐）", text: $titleText)
                        }

                        Picker("消费分类", selection: $selectedCategory) {
                            ForEach(ExpenseCategory.allCases.filter { !$0.isIncome }, id: \.self) { cat in
                                Label(L10n.tr(cat.rawValue), systemImage: cat.icon).tag(cat)
                            }
                        }

                        DatePicker("消费时间", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])

                        DisclosureGroup("查看识别到的小票原文", isExpanded: $isShowingRawText) {
                            Text(recognizedText.isEmpty ? "（未识别到文字）" : recognizedText)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        Button {
                            confirmAndSave()
                        } label: {
                            Label("确认记账", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.vertical, 2)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(L10n.tr(errorMessage)).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("拍小票记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCamera) {
                ReceiptCameraView { image in
                    images.append(image)
                    showingCamera = false
                }
            }
            .onChange(of: selectedItems) { _, items in
                Task { await loadPhotos(items) }
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        await MainActor.run {
            images.append(contentsOf: loaded)
            errorMessage = loaded.isEmpty && images.isEmpty ? "未读取到图片" : nil
        }
    }

    private func recognizeReceipt() async {
        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }
        do {
            var pages: [String] = []
            for image in images {
                pages.append(try await OCRService.shared.recognizeText(from: image))
            }
            let text = pages.joined(separator: "\n")
            let parsed = ReceiptScanParser.parse(text)

            await MainActor.run {
                recognizedText = text
                selectedCurrency = ExpenseCurrency.detectExplicitCurrency(in: text) ?? ExpenseCurrency.preferred()
                amountText = parsed.amount > 0 ? String(format: "%.2f", parsed.amount) : ""
                titleText = parsed.title
                selectedCategory = parsed.category
                selectedDate = parsed.date
                candidateAmounts = parsed.candidateAmounts
                recognitionConfidence = parsed.confidence
                confidenceReason = parsed.confidenceReason
                hasParsed = true
                isProcessing = false
                Haptic.success()
            }
        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmAndSave() {
        let cleanAmtStr = amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amt = Double(cleanAmtStr), amt > 0 else {
            errorMessage = "请输入大于 0 的有效消费金额"
            return
        }

        let cleanTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? "小票消费" : cleanTitle
        let isForeign = selectedCurrency != .cny
        let rate = selectedCurrency.currentRateToCNY
        let finalCNY = isForeign ? selectedCurrency.convertToCNY(amt, rate: rate) : amt

        let finalResult = ExpenseParseResult(
            amount: finalCNY,
            isIncome: false,
            category: selectedCategory,
            title: resolvedTitle,
            date: selectedDate,
            currency: selectedCurrency,
            foreignAmount: isForeign ? amt : nil,
            exchangeRateToCNY: isForeign ? rate : nil
        )
        onSave(finalResult, recognizedText, images.first?.jpegData(compressionQuality: 0.82))
        Haptic.success()
        dismiss()
    }
}

// MARK: - 小票智能解析与置信度评估

/// 小票解析结果的 App 侧视图：把 AssistantCore 的 `ReceiptParseResult`
/// （categoryRaw 为 `ExpenseCategory.rawValue`）映射回枚举。
/// 解析正则本体只有一份，位于 AssistantCore `ReceiptTextParser`。
struct ReceiptScanOutcome {
    var amount: Double
    var title: String
    var category: ExpenseCategory
    var date: Date
    var confidence: Double
    var confidenceReason: String?
    var candidateAmounts: [Double]
}

enum ReceiptScanParser {
    static func parse(_ text: String) -> ReceiptScanOutcome {
        let parsed = AssistantCore.ReceiptTextParser.parse(text)
        return ReceiptScanOutcome(
            amount: parsed.amount,
            title: parsed.title,
            category: ExpenseCategory(rawValue: parsed.categoryRaw) ?? .shopping,
            date: parsed.date,
            confidence: parsed.confidence,
            confidenceReason: parsed.confidenceReason,
            candidateAmounts: parsed.candidateAmounts
        )
    }
}

// MARK: - 相机取景控制器

private struct ReceiptCameraView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ReceiptCameraView
        init(_ parent: ReceiptCameraView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
