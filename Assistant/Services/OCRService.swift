import AssistantCore
import Foundation
import UIKit
import Vision

/// 图片智能识别为待办事项的结构化结果
struct ImageTodoRecognitionResult: Sendable {
    var title: String
    var type: TodoType
    var dueAt: Date?
    var station: String?
    var location: String?
    var pickupCode: String?
    var detail: String?
    var timeSlotText: String?
    var qrCodePayload: String?
    var qrCodeImageData: Data?
    var attachmentImageData: Data?
    var rawText: String

    init(
        title: String,
        type: TodoType = .event,
        dueAt: Date? = nil,
        station: String? = nil,
        location: String? = nil,
        pickupCode: String? = nil,
        detail: String? = nil,
        timeSlotText: String? = nil,
        qrCodePayload: String? = nil,
        qrCodeImageData: Data? = nil,
        attachmentImageData: Data? = nil,
        rawText: String = ""
    ) {
        self.title = title
        self.type = type
        self.dueAt = dueAt
        self.station = station
        self.location = location
        self.pickupCode = pickupCode
        self.detail = detail
        self.timeSlotText = timeSlotText
        self.qrCodePayload = qrCodePayload
        self.qrCodeImageData = qrCodeImageData
        self.attachmentImageData = attachmentImageData
        self.rawText = rawText
    }
}

/// 离线 OCR 与票务/预约/二维码智能提取服务：使用 iOS 系统自带 Vision 框架
public final class OCRService: Sendable {
    public static let shared = OCRService()

    public init() {}

    /// 从 UIImage 提取识别到的文本行
    public func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = Self.normalizedCGImage(from: image) else {
            throw OCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let recognizedStrings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                let fullText = recognizedStrings.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }

            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 从截屏或照片中同时识别文字（事件、时间、场馆、地点、票种）并提取预约二维码与原图凭证
    func recognizeTodo(from image: UIImage) async throws -> ImageTodoRecognitionResult {
        guard let cgImage = Self.normalizedCGImage(from: image) else {
            throw OCRError.invalidImage
        }

        let attachmentData = image.jpegData(compressionQuality: 0.78)

        let (textObservations, barcodeObservations) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([VNRecognizedTextObservation], [VNBarcodeObservation]), Error>) in
            let textReq = VNRecognizeTextRequest()
            textReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            textReq.usesLanguageCorrection = true
            textReq.recognitionLevel = .accurate

            let barcodeReq = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([textReq, barcodeReq])
                let texts = textReq.results ?? []
                let barcodes = barcodeReq.results ?? []
                continuation.resume(returning: (texts, barcodes))
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // 1. 提取二维码/条形码载荷，并从原图精准裁剪二维码图像区域
        var qrPayload: String? = nil
        var qrCropData: Data? = nil

        let preferredBarcodes = barcodeObservations.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }

        if let bestBarcode = preferredBarcodes.first {
            qrPayload = bestBarcode.payloadStringValue
            qrCropData = Self.cropBarcodeImage(from: cgImage, boundingBox: bestBarcode.boundingBox)
        }

        if qrPayload == nil {
            qrPayload = QRCodeService.detectQRCode(from: image)
        }

        // 2. 结构化分析 OCR 文本行（版面去噪、折行标题合并、时间地点提取）
        let rawLines: [RecognizedLine] = textObservations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { return nil }
            return RecognizedLine(
                text: candidate,
                box: obs.boundingBox,
                lastLineMinY: obs.boundingBox.minY,
                lastLineHeight: obs.boundingBox.height
            )
        }

        var result = Self.parseStructuredTodo(from: rawLines, qrPayload: qrPayload)
        result.qrCodePayload = qrPayload
        result.qrCodeImageData = qrCropData
        result.attachmentImageData = attachmentData
        return result
    }

    // MARK: - 内部版面与语义解析器

    private struct RecognizedLine {
        var text: String
        var box: CGRect
        var lastLineMinY: CGFloat
        var lastLineHeight: CGFloat
    }

    /// 将 UIImage 归一化为正向 CGImage，确保截图与拍照裁剪坐标一致
    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }

    /// 根据 Vision 归一化坐标（左下角原点）裁剪二维码区域并保留留白安静区
    private static func cropBarcodeImage(from cgImage: CGImage, boundingBox: CGRect) -> Data? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 10, imgH > 10 else { return nil }

        let boxW = boundingBox.width * imgW
        let boxH = boundingBox.height * imgH
        let boxX = boundingBox.minX * imgW
        let boxY = (1.0 - boundingBox.maxY) * imgH

        let pad = max(boxW, boxH) * 0.14
        let cropX = max(0, boxX - pad)
        let cropY = max(0, boxY - pad)
        let cropW = min(imgW - cropX, boxW + pad * 2)
        let cropH = min(imgH - cropY, boxH + pad * 2)

        let cropRect = CGRect(x: cropX.rounded(), y: cropY.rounded(), width: cropW.rounded(), height: cropH.rounded())
        guard cropRect.width > 16, cropRect.height > 16,
              let croppedCG = cgImage.cropping(to: cropRect) else { return nil }

        return UIImage(cgImage: croppedCG).pngData()
    }

    /// 核心语义提取：从带有位置框的文本行中提炼事件名称、预约时间、场馆地点与详情
    private static func parseStructuredTodo(from lines: [RecognizedLine], qrPayload: String?) -> ImageTodoRecognitionResult {
        // 按从上到下、从左到右排序
        let sorted = lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.012 {
                return a.box.midY > b.box.midY
            }
            return a.box.minX < b.box.minX
        }

        let rawFullText = sorted.map(\.text).joined(separator: "\n")

        // 过滤顶部系统状态栏、底部导航按钮以及右侧海报缩略图噪点文字
        let ignoreExact: Set<String> = [
            "订单详情", "门票详情", "预约详情", "凭证详情", "详情", "电子票", "入场凭证",
            "已完成", "已预约", "预约成功", "出票成功", "待使用", "待参加", "待消费", "交易成功",
            "返回首页", "查看订单", "申请售后", "联系客服", "分享", "去使用",
            "•••", "◎", "<", ">", "抖音", "微信", "支付宝", "美团", "小红书", "大麦", "猫眼"
        ]

        let filtered = sorted.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || ignoreExact.contains(t) { return false }
            // 顶部状态栏 (y > 0.93)
            if line.box.minY > 0.93 { return false }
            // 底部返回按钮栏 (y < 0.07)
            if line.box.maxY < 0.07 && (t.contains("返回") || t.contains("首页") || t.contains("客服")) {
                return false
            }
            // 右侧海报缩略图内小字噪点（x > 0.55 且处于上部卡片区域，非价格/张数信息）
            if line.box.minX > 0.55 && line.box.minY > 0.62 && !t.contains("¥") && !t.contains("￥") && !t.contains("张") {
                return false
            }
            return true
        }

        // 合并左对齐的多行折行标题（如長标题分为2~3行）
        var merged: [RecognizedLine] = []
        for line in filtered {
            if let last = merged.last {
                let isLeftAligned = abs(last.box.minX - line.box.minX) < 0.035 && line.box.minX < 0.15
                let verticalGap = last.lastLineMinY - line.box.maxY
                let similarHeight = abs(last.lastLineHeight - line.box.height) < 0.010
                let lastIsKeyVal = Self.isMetadataLine(last.text)
                let currIsKeyVal = Self.isMetadataLine(line.text)
                let lastReachedRight = last.box.maxX > 0.48
                if isLeftAligned && verticalGap >= -0.006 && verticalGap < 0.030 && similarHeight && !lastIsKeyVal && !currIsKeyVal && lastReachedRight {
                    var updated = last
                    updated.text += line.text
                    updated.box = last.box.union(line.box)
                    updated.lastLineMinY = line.box.minY
                    updated.lastLineHeight = line.box.height
                    merged[merged.count - 1] = updated
                    continue
                }
            }
            merged.append(line)
        }

        let mergedTexts = merged.map(\.text)

        // 1. 提取场馆 (station) 与 地址 (location)
        var venue: String? = nil
        var address: String? = nil
        var generalTimeRange: String? = nil
        var activityTimeLine: String? = nil
        var ticketTypeInfo: [String] = []
        var attendeeInfo: String? = nil
        var maskedIDInfo: String? = nil

        for t in mergedTexts {
            if let v = Self.extractValue(from: t, prefixes: ["场馆", "展馆", "门店", "影院", "剧院", "景区", "展厅"]) {
                if venue == nil { venue = v }
            } else if let addr = Self.extractValue(from: t, prefixes: ["地点", "地址", "位置", "场馆地址", "详细地址"]) {
                if address == nil { address = addr }
            } else if let act = Self.extractValue(from: t, prefixes: ["活动时间", "入场时间", "演出时间", "参观时间", "预约时间", "使用时间", "检票时间", "场次"]) {
                if activityTimeLine == nil { activityTimeLine = act }
            } else if let tm = Self.extractValue(from: t, prefixes: ["时间", "日期", "展期", "有效期"]) {
                if generalTimeRange == nil { generalTimeRange = tm }
            } else if t.contains("免费预约") || t.contains("标准票") || t.contains("早鸟票") || t.contains("成人票") || t.contains("单人票") || t.contains("双人票") || t.contains("亲子票") || t.contains("VIP票") || (t.contains("¥") && t.contains("张")) || (t.contains("￥") && t.contains("张")) {
                if !ticketTypeInfo.contains(t) {
                    ticketTypeInfo.append(t)
                }
            } else if t.contains("身份证") || t.contains("护照") || t.contains("通行证") {
                if attendeeInfo == nil {
                    attendeeInfo = t
                }
            } else if Self.matchesRegex(t, pattern: "^[0-9]{4,6}[*xX×]{2,}[0-9Xx]{2,4}$") {
                if maskedIDInfo == nil {
                    maskedIDInfo = t.replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: "X", with: "*")
                }
            }
        }

        // 若无显式“场馆：/地点：”前缀，尝试基于地名与场馆后缀特征兜底提取
        if venue == nil {
            for t in mergedTexts where !Self.isDateOrTimeOnly(t) {
                if Self.matchesRegex(t, pattern: ".*(?:会展中心|展览馆|博物馆|美术馆|体育馆|大剧院|艺术中心|科技馆|文化中心|音乐厅|博览中心)$") && t.count <= 24 {
                    venue = t
                    break
                }
            }
        }
        if address == nil {
            for t in mergedTexts {
                if Self.matchesRegex(t, pattern: ".*(?:市|区|县).*(?:路|街|道|巷|弄|大道)[0-9]+号.*") && t.count <= 40 {
                    address = t
                    break
                }
            }
        }

        // 2. 提取预约日期与具体时间 (dueAt & timeSlotText)
        let inferredYear = Self.inferYear(from: mergedTexts) ?? Calendar.current.component(.year, from: .now)
        let (parsedDueAt, parsedSlotDesc) = Self.parseBestEventDate(
            mergedTexts: mergedTexts,
            activityTimeLine: activityTimeLine,
            generalTimeRange: generalTimeRange,
            defaultYear: inferredYear
        )

        // 3. 提取事件主标题 (title)
        var eventTitle: String? = nil
        for t in mergedTexts {
            if Self.isCandidateTitle(t) {
                eventTitle = t
                break
            }
        }

        // 4. 检查是否为快递取件截图
        let ruleEngine = RuleEngine()
        let ruleOutcome = ruleEngine.parse(rawFullText, sender: nil)
        if case .parcel(let parcelInfo) = ruleOutcome, let firstCode = parcelInfo.pickupCodes.first {
            let title = TodoFormatter.parcelTitle(code: firstCode, info: parcelInfo)
            return ImageTodoRecognitionResult(
                title: title,
                type: .parcel,
                dueAt: parsedDueAt,
                station: parcelInfo.station ?? venue,
                location: parcelInfo.location ?? address,
                pickupCode: firstCode,
                detail: parcelInfo.location ?? rawFullText,
                timeSlotText: parsedSlotDesc,
                rawText: rawFullText
            )
        }

        // 5. 组装精简、无冗余的结构化详情 (detail) 与地点 (station / location)
        var summaryTokens: [String] = []

        // 场次时间段（由于日期已体现在截止时间 dueAt 中，此处仅提炼时间段如 13:00-18:00场，避免与截止时间重复）
        if let slot = parsedSlotDesc ?? activityTimeLine {
            if let rangeMatch = Self.extractTimeSlotOnly(from: slot) {
                summaryTokens.append("\(rangeMatch)场")
            } else if parsedDueAt == nil {
                summaryTokens.append(slot)
            }
        }

        // 票种去重与精简（如 "免费预约 免费预约 ¥0" -> "免费预约"）
        if !ticketTypeInfo.isEmpty {
            let cleanedTicket = Self.cleanTicketSummary(from: ticketTypeInfo.joined(separator: " "))
            if !cleanedTicket.isEmpty {
                summaryTokens.append(cleanedTicket)
            }
        }

        // 预约人姓名精简（去除 "居民身份证 (330122****2716)" 等冗长证件尾缀）
        if let attendee = attendeeInfo {
            let cleanName = Self.cleanAttendeeName(attendee)
            if !cleanName.isEmpty {
                summaryTokens.append(cleanName)
            }
        }

        let finalStation = venue ?? address
        let finalLocation: String? = {
            if let v = venue, let a = address {
                let shortAddr = a.replacingOccurrences(of: "上海市", with: "")
                return shortAddr.contains(v) ? shortAddr : "\(v) · \(shortAddr)"
            }
            return address ?? venue
        }()

        let rawTitle = eventTitle ?? venue ?? "图片识别待办事项"
        let finalTitle = Self.condenseEventTitle(rawTitle)
        let finalDetail = summaryTokens.isEmpty ? nil : summaryTokens.joined(separator: " · ")

        // 判断具体待办类型
        let todoType: TodoType = {
            if finalTitle.contains("高铁") || finalTitle.contains("火车") || finalTitle.contains("航班") || finalTitle.contains("机票") {
                return .travelBooking
            }
            if qrPayload != nil || venue != nil || address != nil || parsedDueAt != nil || rawFullText.contains("预约") || rawFullText.contains("场馆") || rawFullText.contains("活动时间") || rawFullText.contains("门票") {
                return .event
            }
            return .general
        }()

        return ImageTodoRecognitionResult(
            title: finalTitle,
            type: todoType,
            dueAt: parsedDueAt,
            station: finalStation,
            location: finalLocation,
            pickupCode: nil,
            detail: finalDetail,
            timeSlotText: parsedSlotDesc,
            rawText: rawFullText
        )
    }

    // MARK: - 标题与详情智能精简（去除冗余副标题、重复词与长串证件号）

    /// 在保证语义清晰的前提下，缩减过长的展会/活动标题字数
    static func condenseEventTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        // 1. 去除「暨...」「——...」「｜...」等副标题后缀（当主标题已足够清晰时）
        let subtitleSeparators = ["暨", "——", "—", "｜", "|", "·暨"]
        for sep in subtitleSeparators {
            if let range = s.range(of: sep) {
                let prefix = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.count >= 5 {
                    s = prefix
                }
            }
        }

        // 2. 若标题仍偏长（> 14 字），去除夹在中间的修饰词「国际」「首届」「中国」等冗余词
        if s.count > 14 {
            s = s.replacingOccurrences(of: "国际", with: "")
        }

        // 3. 若同时包含英文缩写+年份前缀（如 WTCC2026）且总长仍超过 15 字，精简年份保留缩写或反之
        if s.count > 15,
           let regex = try? NSRegularExpression(pattern: "^([A-Za-z]{2,8})20\\d{2}(.+)$"),
           let match = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)),
           let r1 = Range(match.range(at: 1), in: s),
           let r2 = Range(match.range(at: 2), in: s) {
            s = String(s[r1]) + String(s[r2])
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将多行冗长的 OCR 详情精简为清爽的一行摘要（同时兼容已入库旧数据的实时清洗）
    static func condenseEventDetail(_ rawDetail: String?, hasDueAt: Bool = true) -> String? {
        guard let raw = rawDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // 如果已经是精简格式（单行且不含冗余前缀），直接返回
        if !raw.contains("\n") && !raw.contains("居民身份证") && !raw.contains("免费预约 免费预约") && !raw.hasPrefix("活动时间：") {
            return raw
        }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parts: [String] = []
        for line in lines {
            if line.hasPrefix("展期：") || line.hasPrefix("展期:") {
                // 已有具体预约场次时，忽略整段展期范围
                continue
            } else if line.hasPrefix("活动时间：") || line.hasPrefix("活动时间:") {
                let val = line.replacingOccurrences(of: "活动时间：", with: "").replacingOccurrences(of: "活动时间:", with: "").trimmingCharacters(in: .whitespaces)
                if let slot = extractTimeSlotOnly(from: val) {
                    parts.append("\(slot)场")
                } else if !hasDueAt && !val.isEmpty {
                    parts.append(val)
                }
            } else if line.hasPrefix("票务：") || line.hasPrefix("票务:") {
                let val = line.replacingOccurrences(of: "票务：", with: "").replacingOccurrences(of: "票务:", with: "")
                let cleaned = cleanTicketSummary(from: val)
                if !cleaned.isEmpty {
                    parts.append(cleaned)
                }
            } else if line.hasPrefix("预约人：") || line.hasPrefix("预约人:") {
                let val = line.replacingOccurrences(of: "预约人：", with: "").replacingOccurrences(of: "预约人:", with: "")
                let cleaned = cleanAttendeeName(val)
                if !cleaned.isEmpty {
                    parts.append(cleaned)
                }
            } else {
                parts.append(line)
            }
        }

        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    private static func extractTimeSlotOnly(from text: String) -> String? {
        let pattern = "(\\d{1,2}:\\d{2})\\s*[-~至–—]\\s*(\\d{1,2}:\\d{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[r1])-\(text[r2])"
    }

    private static func cleanTicketSummary(from text: String) -> String {
        let rawTokens = text.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "¥0" && $0 != "￥0" && $0 != "¥0.0" && $0 != "¥0.00" }
        var seen = Set<String>()
        var unique: [String] = []
        for token in rawTokens {
            if !seen.contains(token) {
                seen.insert(token)
                unique.append(token)
            }
        }
        return unique.joined(separator: " ")
    }

    private static func cleanAttendeeName(_ raw: String) -> String {
        var s = raw
        // 移除括号及括号内脱敏身份证号
        if let regex = try? NSRegularExpression(pattern: "[（\\(][^）\\)]*[）\\)]") {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
        }
        for noise in ["居民身份证", "身份证", "港澳台居民居住证", "护照"] {
            s = s.replacingOccurrences(of: noise, with: "")
        }
        // 移除连续数字或脱敏号段
        if let regex = try? NSRegularExpression(pattern: "\\d{3,}[\\*\\d]+[0-9Xx]?") {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 辅助匹配规则

    private static func isMetadataLine(_ text: String) -> Bool {
        let prefixes = [
            "时间", "场馆", "地点", "地址", "活动时间", "入场时间", "演出时间", "参观时间",
            "预约时间", "日期", "场次", "位置", "票种", "票价", "状态", "订单", "实付", "合计"
        ]
        for p in prefixes {
            if text.hasPrefix("\(p)：") || text.hasPrefix("\(p):") {
                return true
            }
        }
        return isDateOrTimeOnly(text)
    }

    private static func extractValue(from line: String, prefixes: [String]) -> String? {
        for p in prefixes {
            for sep in ["：", ":"] {
                let prefix = p + sep
                if line.hasPrefix(prefix) {
                    let val = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    private static func isDateOrTimeOnly(_ text: String) -> Bool {
        matchesRegex(text, pattern: "^[0-9年./月日\\-~至:：\\s星期周一套二三四五六天]+$")
    }

    private static func isCandidateTitle(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return false }
        if isMetadataLine(t) { return false }
        if isDateOrTimeOnly(t) { return false }
        if t.contains("居民身份证") || t.contains("免费预约") || t.hasPrefix("¥") || t.hasPrefix("￥") {
            return false
        }
        if matchesRegex(t, pattern: "^[0-9]{4,6}[*xX×]{2,}[0-9Xx]{2,4}$") {
            return false
        }
        return true
    }

    private static func inferYear(from lines: [String]) -> Int? {
        let pattern = "(20[2-3][0-9])[年./-]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in lines {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, range: range),
               let r = Range(match.range(at: 1), in: line),
               let y = Int(line[r]) {
                return y
            }
        }
        return nil
    }

    private static func parseBestEventDate(
        mergedTexts: [String],
        activityTimeLine: String?,
        generalTimeRange: String?,
        defaultYear: Int
    ) -> (Date?, String?) {
        let cal = Calendar.current

        // 优先级 1：解析带具体时间段的行（如 "10月24日 13:00-18:00" 或 "2026-10-24 13:00"）
        let timeCandidates = ([activityTimeLine].compactMap { $0 }) + mergedTexts
        let dateTimePattern = "(?:(20[2-3][0-9])[年./-])?([01]?[0-9])[月./-]([0-3]?[0-9])日?\\s*(?:周[一二三四五六日天]|星期[一二三四五六日天])?\\s*([0-2]?[0-9]):([0-5][0-9])(?:\\s*[-~至–—]\\s*([0-2]?[0-9]):([0-5][0-9]))?"

        if let regex = try? NSRegularExpression(pattern: dateTimePattern) {
            for candidate in timeCandidates {
                let nsRange = NSRange(location: 0, length: candidate.utf16.count)
                if let match = regex.firstMatch(in: candidate, range: nsRange) {
                    let year: Int = {
                        if match.range(at: 1).location != NSNotFound,
                           let r = Range(match.range(at: 1), in: candidate),
                           let y = Int(candidate[r]) {
                            return y
                        }
                        return defaultYear
                    }()
                    guard let mRange = Range(match.range(at: 2), in: candidate),
                          let dRange = Range(match.range(at: 3), in: candidate),
                          let hRange = Range(match.range(at: 4), in: candidate),
                          let minRange = Range(match.range(at: 5), in: candidate),
                          let month = Int(candidate[mRange]),
                          let day = Int(candidate[dRange]),
                          let hour = Int(candidate[hRange]),
                          let minute = Int(candidate[minRange]) else { continue }

                    var comps = DateComponents()
                    comps.year = year
                    comps.month = month
                    comps.day = day
                    comps.hour = hour
                    comps.minute = minute
                    if let date = cal.date(from: comps) {
                        var desc = String(format: "%d年%d月%d日 %02d:%02d", year, month, day, hour, minute)
                        if match.range(at: 6).location != NSNotFound,
                           match.range(at: 7).location != NSNotFound,
                           let ehRange = Range(match.range(at: 6), in: candidate),
                           let emRange = Range(match.range(at: 7), in: candidate) {
                            desc += "-\(candidate[ehRange]):\(candidate[emRange])"
                        }
                        return (date, desc)
                    }
                }
            }
        }

        // 优先级 2：解析单日预约日期（如 "2026年10月24日-10月24日"）
        let rangePattern = "(?:(20[2-3][0-9])[年./-])?([01]?[0-9])[月./-]([0-3]?[0-9])日?\\s*[-~至–—]\\s*(?:(20[2-3][0-9])[年./-])?([01]?[0-9])[月./-]([0-3]?[0-9])日?"
        var fallbackRangeDate: (Date, String)? = nil

        if let regex = try? NSRegularExpression(pattern: rangePattern) {
            for candidate in mergedTexts {
                let nsRange = NSRange(location: 0, length: candidate.utf16.count)
                if let match = regex.firstMatch(in: candidate, range: nsRange) {
                    let year: Int = {
                        if match.range(at: 1).location != NSNotFound,
                           let r = Range(match.range(at: 1), in: candidate),
                           let y = Int(candidate[r]) {
                            return y
                        }
                        return defaultYear
                    }()
                    guard let m1R = Range(match.range(at: 2), in: candidate),
                          let d1R = Range(match.range(at: 3), in: candidate),
                          let m2R = Range(match.range(at: 5), in: candidate),
                          let d2R = Range(match.range(at: 6), in: candidate),
                          let m1 = Int(candidate[m1R]), let d1 = Int(candidate[d1R]),
                          let m2 = Int(candidate[m2R]), let d2 = Int(candidate[d2R]) else { continue }

                    var comps = DateComponents()
                    comps.year = year
                    comps.month = m1
                    comps.day = d1
                    comps.hour = 9
                    comps.minute = 0
                    if let date = cal.date(from: comps) {
                        if m1 == m2 && d1 == d2 {
                            return (date, "\(year)年\(m1)月\(d1)日")
                        } else if fallbackRangeDate == nil {
                            fallbackRangeDate = (date, "\(year).\(m1).\(d1)-\(m2).\(d2)")
                        }
                    }
                }
            }
        }

        if let fallbackRangeDate {
            return (fallbackRangeDate.0, fallbackRangeDate.1)
        }

        return (nil, nil)
    }

    private static func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

public enum OCRError: LocalizedError {
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无效的图片格式或无法读取图像数据"
        }
    }
}
