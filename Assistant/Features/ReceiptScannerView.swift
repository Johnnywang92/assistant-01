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
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            let parsed = ReceiptTextParser.parse(text)

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

struct ReceiptScanOutcome {
    var amount: Double
    var title: String
    var category: ExpenseCategory
    var date: Date
    var confidence: Double
    var confidenceReason: String?
    var candidateAmounts: [Double]
}

private enum ReceiptTextParser {
    static func parse(_ text: String) -> ReceiptScanOutcome {
        let candidates = extractAllCandidateAmounts(from: text)
        let labeledTotal = extractLabeledTotalAmount(from: text)
        let merchant = extractMerchantOrTitle(from: text)
        let category = guessCategory(merchant: merchant, text: text)
        let date = OmniboxPlanner.extractTransactionDate(from: text) ?? .now

        if let explicit = labeledTotal {
            return ReceiptScanOutcome(
                amount: explicit,
                title: merchant,
                category: category,
                date: date,
                confidence: 0.92,
                confidenceReason: nil,
                candidateAmounts: candidates
            )
        } else if let maxCandidate = candidates.max() {
            return ReceiptScanOutcome(
                amount: maxCandidate,
                title: merchant,
                category: category,
                date: date,
                confidence: 0.60,
                confidenceReason: "未明确检测到“合计/实付”标签，已提取最大可能金额，请核对",
                candidateAmounts: candidates
            )
        } else {
            return ReceiptScanOutcome(
                amount: 0.0,
                title: merchant,
                category: category,
                date: date,
                confidence: 0.25,
                confidenceReason: "未能自动识别金额，请手动输入或重拍",
                candidateAmounts: []
            )
        }
    }

    /// 提取明确带有「合计/实付/总计/应付」等字样的金额
    private static func extractLabeledTotalAmount(from text: String) -> Double? {
        let patterns = [
            "(?:合计|总计|实付|应付|实际支付|支付金额|订单金额|实收|消费金额|账单金额|结算金额|小计|TOTAL|Total|PAID)\\s*[:：]?\\s*[¥￥]?\\s*([0-9]+(?:[.,][0-9]{1,2})?)",
            "[¥￥]\\s*([0-9]+(?:[.,][0-9]{1,2})?)\\s*(?:元)?\\s*(?:合计|实付|应付|实收)",
            "(?:合计|实付|应付|实收)\\s*[¥￥]?\\s*([0-9]+(?:[.,][0-9]{1,2})?)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range(at: 1).location != NSNotFound,
                  let range = Range(match.range(at: 1), in: text),
                  let amount = Double(text[range].replacingOccurrences(of: ",", with: ".")),
                  amount > 0 else { continue }
            return amount
        }
        return nil
    }

    /// 提取全文中所有合法的金额数值
    private static func extractAllCandidateAmounts(from text: String) -> [Double] {
        let patterns = [
            "[¥￥]\\s*([0-9]+(?:[.,][0-9]{1,2})?)",
            "([0-9]+(?:[.,][0-9]{1,2})?)\\s*(?:元|块)",
            "\\b([0-9]+\\.[0-9]{2})\\b"
        ]
        var amounts: Set<Double> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches where match.range(at: 1).location != NSNotFound {
                if let range = Range(match.range(at: 1), in: text),
                   let val = Double(text[range].replacingOccurrences(of: ",", with: ".")),
                   val > 0 && val < 500000 {
                    amounts.insert(val)
                }
            }
        }
        return amounts.sorted(by: >)
    }

    /// 从头部提取商户名或门店名称
    private static func extractMerchantOrTitle(from text: String) -> String {
        // 1. 尝试匹配显式的商户/门店标签
        let labeledPatterns = [
            "(?:商户名称|门店名称|商户|门店|店铺|收款方|商户全称)\\s*[:：]\\s*([^\\n\\r]{2,20})",
            "欢迎光临\\s*([^\\n\\r]{2,20})"
        ]
        for pattern in labeledPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }

        // 2. 检查前几行非空文本，排除常规表头、分隔线与纯数字
        let ignoreKeywords = ["结账单", "收银单", "销售小票", "发票", "存根", "POS签购单", "明细", "小票", "小票消费", "欢迎光临", "交易凭条"]
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.prefix(6) {
            if line.count >= 2 && line.count <= 25 {
                let isIgnore = ignoreKeywords.contains { line.contains($0) }
                let isPureDigitsOrSymbols = line.range(of: "^[0-9\\-—*#:=. /]+$", options: .regularExpression) != nil
                if !isIgnore && !isPureDigitsOrSymbols {
                    return line
                }
            }
        }

        return "小票消费"
    }

    /// 智能分类判定
    private static func guessCategory(merchant: String, text: String) -> ExpenseCategory {
        let combined = merchant + " " + text

        let mapping: [(ExpenseCategory, [String])] = [
            (.food, [
                "餐饮", "饭店", "餐馆", "火锅", "咖啡", "奶茶", "快餐", "美食", "茶饮", "面馆",
                "米线", "烤肉", "料理", "酒楼", "烘焙", "甜品", "面包", "堂食", "外卖", "麦当劳",
                "肯德基", "星巴克", "瑞幸", "喜茶", "蜜雪", "汉堡", "披萨", "必胜客", "海底捞",
                "西贝", "真功夫", "吉野家", "味千", "老乡鸡", "霸王茶姬", "茶百道", "茶颜悦色",
                "萨莉亚", "达美乐", "烧烤", "麻辣烫", "小吃", "早餐", "午餐", "晚餐"
            ]),
            (.living, [
                "超市", "便利店", "生鲜", "百货", "果蔬", "菜场", "粮油", "日用", "全家", "罗森",
                "7-11", "7-ELEVEN", "大润发", "沃尔玛", "永辉", "盒马", "物美", "华润万家",
                "家乐福", "屈臣氏", "名创优品", "便利蜂", "杂货", "菜市", "百联"
            ]),
            (.transport, [
                "加油", "中石化", "中石油", "中国海油", "加气", "充电桩", "停车", "收费站", "高速",
                "滴滴", "出租车", "打车", "地铁", "公交", "ETC", "铁路", "客运", "高德打车"
            ]),
            (.medical, [
                "药房", "药店", "大药房", "同仁堂", "海王星辰", "益丰", "国大", "老百姓", "一心堂",
                "医院", "门诊", "诊所", "体检", "卫生院", "口腔", "眼科", "处方", "挂号"
            ]),
            (.entertainment, [
                "影城", "影院", "电影", "万达影城", "大地影院", "KTV", "密室", "剧本杀", "乐园",
                "游乐", "网吧", "电竞", "健身", "游泳", "保龄球", "桌游"
            ]),
            (.digital, [
                "数码", "手机", "电脑", "专卖店", "Apple", "苹果", "华为", "小米", "OPPO",
                "vivo", "大疆", "联想", "电子产品", "苏宁易购"
            ]),
            (.pets, [
                "宠物", "萌宠", "猫粮", "狗粮", "宠物医院", "宠物洗护", "猫砂"
            ])
        ]

        for (cat, keywords) in mapping {
            if keywords.contains(where: { combined.localizedCaseInsensitiveContains($0) }) {
                return cat
            }
        }

        return .shopping
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
