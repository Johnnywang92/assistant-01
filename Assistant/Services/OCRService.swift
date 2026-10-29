import AssistantCore
import Foundation
import SwiftUI
import UIKit
import Vision

/// 接站/接机汇合地点类型
public enum TravelPickupDestinationKind: String, CaseIterable, Identifiable, Sendable {
    case stationOrAirport = "火车站/机场"
    case subwayStation = "地铁站"
    case customSpot = "指定上客点"

    public var id: String { rawValue }
    public var displayName: String { L10n.tr(rawValue) }
}

/// 火车票/机票截图识别出的接人（或出行）结构化元数据
public struct TravelPickupMetadata: Sendable, Equatable {
    public var isFlight: Bool
    public var tripNumber: String
    public var passengerName: String?
    public var departureStation: String?
    public var arrivalStation: String
    public var departureAt: Date?
    public var arrivalAt: Date
    public var seatInfo: String?
    public var gateInfo: String?
    public var isPickupMode: Bool
    public var destinationKind: TravelPickupDestinationKind
    public var subwayStationName: String
    public var customSpotName: String
    public var advanceMinutes: Int

    public init(
        isFlight: Bool = false,
        tripNumber: String,
        passengerName: String? = nil,
        departureStation: String? = nil,
        arrivalStation: String,
        departureAt: Date? = nil,
        arrivalAt: Date,
        seatInfo: String? = nil,
        gateInfo: String? = nil,
        isPickupMode: Bool = true,
        destinationKind: TravelPickupDestinationKind = .stationOrAirport,
        subwayStationName: String = "",
        customSpotName: String = "",
        advanceMinutes: Int? = nil
    ) {
        self.isFlight = isFlight
        self.tripNumber = tripNumber
        self.passengerName = passengerName
        self.departureStation = departureStation
        self.arrivalStation = arrivalStation
        self.departureAt = departureAt
        self.arrivalAt = arrivalAt
        self.seatInfo = seatInfo
        self.gateInfo = gateInfo
        self.isPickupMode = isPickupMode
        self.destinationKind = destinationKind
        let cleanArr = arrivalStation.replacingOccurrences(of: "站", with: "")
        self.subwayStationName = subwayStationName.isEmpty ? "\(cleanArr)地铁站" : subwayStationName
        self.customSpotName = customSpotName.isEmpty ? "\(cleanArr)\(isFlight ? "机场" : "站")网约车/停车场接客点" : customSpotName
        self.advanceMinutes = advanceMinutes ?? (isFlight ? 45 : 30)
    }

    /// 基准票面时间（接人模式按终到时间，本人出行按发车/起飞时间）
    public var baseTicketTime: Date {
        isPickupMode ? arrivalAt : (departureAt ?? arrivalAt)
    }

    /// 扣除提前量后的计划到达车站/机场/地铁站时间
    public var plannedTargetTime: Date {
        baseTicketTime.addingTimeInterval(TimeInterval(-advanceMinutes * 60))
    }

    /// 解析后的汇合/到达地点名称
    public var resolvedLocation: String {
        if isPickupMode {
            switch destinationKind {
            case .stationOrAirport:
                if isFlight {
                    return arrivalStation.contains("机场") || arrivalStation.contains("航站楼") || arrivalStation.contains("T1") || arrivalStation.contains("T2") || arrivalStation.contains("T3")
                        ? arrivalStation
                        : "\(arrivalStation)机场"
                } else {
                    return arrivalStation.hasSuffix("站") ? arrivalStation : "\(arrivalStation)站"
                }
            case .subwayStation:
                let trimmed = subwayStationName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let cleanArr = arrivalStation.replacingOccurrences(of: "站", with: "")
                    return "\(cleanArr)地铁站"
                }
                return (trimmed.contains("地铁") || trimmed.hasSuffix("站") || trimmed.hasSuffix("口")) ? trimmed : "\(trimmed)地铁站"
            case .customSpot:
                let trimmed = customSpotName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? arrivalStation : trimmed
            }
        } else {
            let dep = departureStation ?? arrivalStation
            if isFlight {
                return dep.contains("机场") || dep.contains("航站楼") ? dep : "\(dep)机场"
            } else {
                return dep.hasSuffix("站") ? dep : "\(dep)站"
            }
        }
    }

    /// 自动生成的待办主标题
    public var resolvedTitle: String {
        let tripBadge = tripNumber.isEmpty ? "" : "（\(tripNumber)）"
        if isPickupMode {
            let personText = (passengerName?.isEmpty == false) ? passengerName! : "亲友"
            return "去\(resolvedLocation)接\(personText)\(tripBadge)"
        } else {
            let tripText = tripNumber.isEmpty ? (isFlight ? "航班" : "列车") : tripNumber
            return "乘坐 \(tripText) 前往\(arrivalStation)"
        }
    }

    /// 自动生成的结构化详情说明
    public var resolvedDetail: String {
        let hmFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
        let arrHM = hmFormatter.string(from: arrivalAt)
        let targetHM = hmFormatter.string(from: plannedTargetTime)
        let depHM = departureAt.map { hmFormatter.string(from: $0) }

        var parts: [String] = []
        let tripLabel = tripNumber.isEmpty ? (isFlight ? "航班" : "列车") : tripNumber

        if isPickupMode {
            let depClause = (departureStation != nil && depHM != nil) ? "（\(departureStation!) \(depHM!) 始发）" : ""
            parts.append("\(tripLabel) \(arrHM) 到达\(arrivalStation)\(depClause)")
            if advanceMinutes > 0 {
                parts.append("提前\(advanceMinutes)分钟（\(targetHM)）到\(resolvedLocation)")
            } else {
                parts.append("准点（\(arrHM)）到\(resolvedLocation)")
            }
        } else {
            if let dep = departureStation, let dHM = depHM {
                parts.append("\(tripLabel) \(dHM) \(dep)发车 → \(arrHM) 到\(arrivalStation)")
            } else {
                parts.append("\(tripLabel) 预计 \(arrHM) 到达\(arrivalStation)")
            }
            if advanceMinutes > 0 {
                parts.append("提前\(advanceMinutes)分钟（\(targetHM)）到站候车")
            }
        }

        if let p = passengerName, !p.isEmpty {
            parts.append("乘\(isFlight ? "机" : "车")人：\(p)")
        }
        if let s = seatInfo, !s.isEmpty {
            parts.append("座位：\(s)")
        }
        if let g = gateInfo, !g.isEmpty {
            parts.append("\(isFlight ? "登机口" : "检票口")：\(g)")
        }
        return parts.joined(separator: " · ")
    }
}

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
    var travelPickup: TravelPickupMetadata?
    var rawText: String
    var confidence: Double
    var confidenceReason: String?
    var suggestedTypes: [TodoType]

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
        travelPickup: TravelPickupMetadata? = nil,
        rawText: String = "",
        confidence: Double = 0.85,
        confidenceReason: String? = nil,
        suggestedTypes: [TodoType] = []
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
        self.travelPickup = travelPickup
        self.rawText = rawText
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.suggestedTypes = suggestedTypes.isEmpty ? [type] : suggestedTypes
    }
}

/// 离线 OCR 与票务/预约/二维码智能提取服务：使用 iOS 系统自带 Vision 框架
public final class OCRService: Sendable {
    public static let shared = OCRService()

    public init() {}

    /// 从 UIImage 提取识别到的文本行（在后台线程执行 Vision 推理，避免阻塞主线程且消除 Continuation 双重 resume 风险）
    public func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = Self.normalizedCGImage(from: image) else {
            throw OCRError.invalidImage
        }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            return recognizedStrings.joined(separator: "\n")
        }.value
    }

    /// 从截屏或照片中同时识别文字（事件、时间、场馆、地点、票种）并提取预约二维码与原图凭证
    func recognizeTodo(from image: UIImage) async throws -> ImageTodoRecognitionResult {
        guard let cgImage = Self.normalizedCGImage(from: image) else {
            throw OCRError.invalidImage
        }

        let attachmentData = image.jpegData(compressionQuality: 0.78)

        let (textObservations, barcodeObservations) = try await Task.detached(priority: .userInitiated) {
            let textReq = VNRecognizeTextRequest()
            textReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            textReq.usesLanguageCorrection = true
            textReq.recognitionLevel = .accurate

            let barcodeReq = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([textReq, barcodeReq])
            let texts = textReq.results ?? []
            let barcodes = barcodeReq.results ?? []
            return (texts, barcodes)
        }.value

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

        // 0. 优先检测是否为火车票/高铁票或机票行程截图（默认推测为去车站/机场/地铁站接人，并预留提前量）
        let defaultYear = Self.inferYear(from: sorted.map(\.text)) ?? Calendar.current.component(.year, from: .now)
        if let ticketResult = Self.parseTravelTicketPickup(from: sorted, rawFullText: rawFullText, defaultYear: defaultYear) {
            return ticketResult
        }

        // 过滤顶部系统状态栏、底部导航按钮以及右侧海报缩略图噪点文字
        let ignoreExact: Set<String> = [
            "订单详情", "门票详情", "预约详情", "凭证详情", "详情", "电子票", "入场凭证",
            "电影票详情", "演出票详情", "机票详情", "火车票详情", "行程详情", "我的电影票", "电影票",
            "取电影票", "扫码入场", "如何取票", "取票凭证", "取票码", "取票号",
            "本单权益", "电子纪念票", "定制专属取票语", "定制票纸纪念语",
            "添加到系统日历", "添加到日历", "开场提醒你",
            "已完成", "已预约", "预约成功", "出票成功", "待使用", "待参加", "待消费", "交易成功", "出票中",
            "返回首页", "查看订单", "申请售后", "联系客服", "分享", "去使用", "去看看", "映后发放",
            "•••", "◎", "<", ">", "＞", "＜", "抖音", "微信", "支付宝", "美团", "小红书", "大麦", "猫眼", "淘票票", "猫眼电影"
        ]

        let filtered = sorted.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || ignoreExact.contains(t) { return false }
            // 顶部状态栏 (y > 0.93)
            if line.box.minY > 0.93 { return false }
            // 顶部居中导航栏详情标题（如 y > 0.86 处的 "电影票详情" / "xxx详情"）
            if line.box.minY > 0.86 && (t.hasSuffix("详情") || t.contains("票夹") || t.contains("凭证") || t == "电影票") {
                return false
            }
            // 底部返回按钮栏及权益/活动浮层 (y < 0.08)
            if line.box.maxY < 0.08 && (t.contains("返回") || t.contains("首页") || t.contains("客服") || t.contains("去看看") || t.contains("发放") || t.contains("积分") || t.contains("纪念")) {
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
            if let v = Self.extractValue(from: t, prefixes: ["场馆", "展馆", "门店", "影院", "影城", "剧院", "景区", "展厅"]) {
                if venue == nil { venue = Self.cleanVenueName(v) }
            } else if let addr = Self.extractValue(from: t, prefixes: ["地点", "地址", "位置", "场馆地址", "详细地址"]) {
                if address == nil { address = Self.cleanVenueName(addr) }
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

        // 影院特征提取（若存在电影院/影城，支持分店名及导航箭头清理）
        if venue == nil {
            for t in mergedTexts where !Self.isDateOrTimeOnly(t) {
                let cleaned = Self.cleanVenueName(t)
                if cleaned.contains("取电影票") || cleaned.contains("取票") || cleaned.contains("张电影票") { continue }
                if cleaned.hasSuffix("厅") || Self.matchesRegex(cleaned, pattern: ".*[0-9]+号.*厅.*") { continue }
                if (cleaned.contains("影城") || cleaned.contains("影院") || cleaned.contains("电影院") || cleaned.contains("影剧院") || cleaned.contains("百老汇")) && cleaned.count >= 4 && cleaned.count <= 35 {
                    venue = cleaned
                    break
                }
            }
        }

        // 若无显式“场馆：/地点：”前缀，尝试基于地名与场馆后缀特征兜底提取
        if venue == nil {
            for t in mergedTexts where !Self.isDateOrTimeOnly(t) {
                let cleaned = Self.cleanVenueName(t)
                if Self.matchesRegex(cleaned, pattern: ".*(?:会展中心|展览馆|博物馆|美术馆|体育馆|大剧院|剧场|剧院|影院|影城|电影院|艺术中心|科技馆|文化中心|音乐厅|博览中心|中心广场|体育场|大礼堂)(?:[（\\(].*?[）\\)]|[\\s·\\-].*?店)?$") && cleaned.count <= 35 {
                    venue = cleaned
                    break
                }
            }
        }
        if address == nil {
            for t in mergedTexts {
                if Self.matchesRegex(t, pattern: ".*(?:市|区|县).*(?:路|街|道|巷|弄|大道)[0-9]+号.*") && t.count <= 40 {
                    address = Self.cleanVenueName(t)
                    break
                }
            }
        }

        // 2. 提取预约日期与具体时间 (dueAt & timeSlotText)
        let inferredYear = Self.inferYear(from: mergedTexts) ?? Calendar.current.component(.year, from: .now)
        var (parsedDueAt, parsedSlotDesc) = Self.parseBestEventDate(
            mergedTexts: mergedTexts,
            activityTimeLine: activityTimeLine,
            generalTimeRange: generalTimeRange,
            defaultYear: inferredYear
        )

        // 电影票截图通常把日期、场次和影厅分散在不同位置，单靠通用预约解析容易漏掉截止时间。
        let isMovieTicket = Self.looksLikeMovieTicket(rawText: rawFullText)
        if isMovieTicket {
            if let movieDate = Self.parseMovieScreeningDate(from: mergedTexts, defaultYear: inferredYear) {
                parsedDueAt = movieDate
            }
            if activityTimeLine == nil,
               let timeLine = mergedTexts.first(where: { Self.matchesRegex($0, pattern: "[0-2]?[0-9]:[0-5][0-9]\\s*[-~至]\\s*[0-2]?[0-9]:[0-5][0-9]") }) {
                parsedSlotDesc = timeLine
            }
        }

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

        var moviePickupCode: String? = nil
        let movieTitle: String? = {
            guard isMovieTicket else { return nil }

            func isMovieTitleCandidate(_ line: String) -> Bool {
                var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                s = s.replacingOccurrences(of: #"^《|》$"#, with: "", options: .regularExpression)
                guard s.count >= 1 && s.count <= 25 else { return false }
                if Self.isDateOrTimeOnly(s) { return false }
                if let v = venue, s == v || s.contains(v) || v.contains(s) { return false }
                if s.contains("影城") || s.contains("影院") || s.contains("电影院") || s.contains("影剧院") { return false }
                if s.hasSuffix("详情") || s.contains("电影票") || s.contains("门票") || s.contains("凭证") || s.contains("订单") { return false }
                if s.contains("开场") || s.contains("放映") || s.contains("小时") || s.contains("分钟") { return false }
                if s.contains("二维码") || s.contains("短信") || s.contains("取票") || s.contains("入场") || s.contains("扫码") { return false }
                if s.contains("日历") || s.contains("提醒你") || s.contains("权益") || s.contains("积分") || s.contains("纪念") || s.contains("去看看") || s.contains("发放") { return false }
                if s.contains("排") && s.contains("座") { return false }
                if s.contains("厅") || s.contains("沙发") || s.contains("认证") || s.contains("VIP") { return false }
                if s.contains("2D") || s.contains("3D") || s.contains("IMAX") || s.contains("原版") || s.contains("国语") || s.contains("粤语") || s.contains("张") { return false }
                if s.contains("，") || s.contains("。") || s.contains("！") || s.contains("？") || s.contains("：") || s.contains(":") || s.contains("~") { return false }
                if Self.matchesRegex(s, pattern: "^[0-9\\s\\-:]+$") { return false }
                if s.contains("今天") || s.contains("明天") || s.contains("后天") || Self.matchesRegex(s, pattern: ".*[0-9]+-[0-9]+.*") { return false }
                return true
            }

            // 优先查找在影院地点之后紧邻的电影标题
            if let v = venue, let venueIndex = mergedTexts.firstIndex(where: { $0.contains(v) || v.contains($0) }) {
                let candidatesAfterVenue = mergedTexts.dropFirst(venueIndex + 1).filter(isMovieTitleCandidate)
                if let best = candidatesAfterVenue.first {
                    return best
                }
            }
            return mergedTexts.filter(isMovieTitleCandidate).first
        }()
        let rawTitle = movieTitle ?? eventTitle ?? venue ?? "图片识别待办事项"
        let finalTitle = isMovieTicket ? "观看《\(Self.condenseEventTitle(rawTitle))》" : Self.condenseEventTitle(rawTitle)
        if isMovieTicket {
            summaryTokens.insert("电影票", at: 0)
            if let seat = mergedTexts.first(where: { Self.matchesRegex($0, pattern: ".*[0-9]+排[0-9]+座.*") }) {
                summaryTokens.append(seat)
            }
            if let hall = mergedTexts.first(where: { $0.contains("厅") && !$0.contains("展厅") && !$0.contains("餐厅") && !$0.contains("客厅") }) {
                if let match = hall.range(of: #".*?([0-9a-zA-Z一二三四五六七八九十]+号)?.*?[0-9a-zA-Z\u4e00-\u9fa5]*厅"#, options: .regularExpression) {
                    summaryTokens.append(String(hall[match]))
                } else {
                    summaryTokens.append(hall)
                }
            }
            for t in mergedTexts {
                if let match = t.range(of: #"(?:取票号|取票码|验证码|票号)[：:]\s*([0-9\s]{6,})"#, options: .regularExpression) {
                    let matchedStr = String(t[match])
                    if let colonIndex = matchedStr.firstIndex(where: { $0 == "：" || $0 == ":" }) {
                        moviePickupCode = String(matchedStr[matchedStr.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }
        let finalDetail = summaryTokens.isEmpty ? nil : summaryTokens.joined(separator: " · ")

        // 6. 细分垂直领域分类与多维度置信度评估
        var detectedType: TodoType = .general
        var detectedConfidence: Double = 0.60
        var confidenceReason: String? = nil
        var candidateTypes: [TodoType] = []

        // (1) 退货寄件
        if rawFullText.contains("退货") || rawFullText.contains("寄件码") || rawFullText.contains("上门取件") || rawFullText.contains("寄件人") || rawFullText.contains("已预约寄件") {
            detectedType = .returnParcel
            detectedConfidence = 0.92
            candidateTypes = [.returnParcel, .parcel, .general]
        }
        // (2) 服药提醒
        else if rawFullText.contains("用法用量") || rawFullText.contains("口服") || rawFullText.contains("处方") || rawFullText.contains("饭前服用") || rawFullText.contains("饭后服用") || rawFullText.contains("早晚各") || (rawFullText.contains("每次") && (rawFullText.contains("片") || rawFullText.contains("粒") || rawFullText.contains("袋"))) {
            detectedType = .medication
            detectedConfidence = 0.93
            candidateTypes = [.medication, .general]
        }
        // (3) 车辆保养与车务
        else if (rawFullText.contains("保养") && (rawFullText.contains("机油") || rawFullText.contains("车辆") || rawFullText.contains("公里") || rawFullText.contains("4s店") || rawFullText.contains("爱车"))) || rawFullText.contains("年检") || rawFullText.contains("交强险") {
            detectedType = .vehicleCare
            detectedConfidence = 0.90
            candidateTypes = [.vehicleCare, .bill, .event]
        }
        // (4) 亲子育儿 / 疫苗
        else if rawFullText.contains("接种证") || rawFullText.contains("预防接种") || rawFullText.contains("儿童保健") || rawFullText.contains("儿科") || (rawFullText.contains("疫苗") && !rawFullText.contains("宠物") && !rawFullText.contains("猫") && !rawFullText.contains("犬")) {
            detectedType = .childVaccine
            detectedConfidence = 0.91
            candidateTypes = [.childVaccine, .childHealth, .event]
        }
        // (5) 宠物照护
        else if rawFullText.contains("猫三联") || rawFullText.contains("狂犬疫苗") || rawFullText.contains("驱虫") || rawFullText.contains("宠物医院") || rawFullText.contains("洗护预约") || (rawFullText.contains("宠物") && (rawFullText.contains("就诊") || rawFullText.contains("挂号"))) {
            detectedType = .pet
            detectedConfidence = 0.92
            candidateTypes = [.pet, .general, .event]
        }
        // (6) 账单 / 还款 / 自动续费
        else if rawFullText.contains("还款日") || rawFullText.contains("最低还款") || rawFullText.contains("应缴金额") || rawFullText.contains("账单金额") || rawFullText.contains("自动续费") || rawFullText.contains("电费缴费") || rawFullText.contains("水费缴费") || rawFullText.contains("燃气费") {
            detectedType = rawFullText.contains("续费") ? .subscription : .bill
            detectedConfidence = 0.88
            candidateTypes = [detectedType, .general]
        }
        // (7) 物品 / 证件临期
        else if rawFullText.contains("保质期至") || rawFullText.contains("有效期限至") || rawFullText.contains("到期换证") || rawFullText.contains("换发身份证") {
            detectedType = .itemExpiry
            detectedConfidence = 0.88
            candidateTypes = [.itemExpiry, .event, .general]
        }
        // (8) 出行行程客票
        else if finalTitle.contains("高铁") || finalTitle.contains("火车") || finalTitle.contains("航班") || finalTitle.contains("机票") || rawFullText.contains("行程信息") {
            detectedType = .travelBooking
            detectedConfidence = 0.90
            candidateTypes = [.travelBooking, .event, .general]
        }
        // (9) 预约 / 活动 / 展览 / 观影
        else if isMovieTicket || qrPayload != nil || venue != nil || address != nil || parsedDueAt != nil || rawFullText.contains("预约") || rawFullText.contains("场馆") || rawFullText.contains("活动时间") || rawFullText.contains("门票") {
            detectedType = .event
            detectedConfidence = isMovieTicket ? 0.95 : (parsedDueAt != nil ? 0.86 : 0.75)
            candidateTypes = [.event, .general]
        } else {
            detectedType = .general
            detectedConfidence = 0.55
            confidenceReason = "未识别到明确的时间、场馆或具体票务凭证，已设为日常待办，请核对"
            candidateTypes = [.general, .event, .parcel]
        }

        if parsedDueAt != nil { detectedConfidence += 0.05 }
        if qrPayload != nil { detectedConfidence += 0.05 }
        if rawTitle == "图片识别待办事项" {
            detectedConfidence = min(detectedConfidence, 0.48)
            confidenceReason = "未能从图片中提炼出准确的标题，建议手动修改标题"
        }
        detectedConfidence = min(1.0, max(0.1, detectedConfidence))

        return ImageTodoRecognitionResult(
            title: finalTitle,
            type: detectedType,
            dueAt: parsedDueAt,
            station: finalStation,
            location: finalLocation,
            pickupCode: moviePickupCode,
            detail: finalDetail,
            timeSlotText: parsedSlotDesc,
            rawText: rawFullText,
            confidence: detectedConfidence,
            confidenceReason: confidenceReason,
            suggestedTypes: candidateTypes
        )
    }

    // MARK: - 标题与详情智能精简（去除冗余副标题、重复词与长串证件号）

    // 性能：行渲染与卡片摘要中高频调用的预编译正则
    private static let condensedYearTitleRegex = try? NSRegularExpression(pattern: "^([A-Za-z]{2,8})20\\d{2}(.+)$")
    private static let timeSlotRegex = try? NSRegularExpression(pattern: "(\\d{1,2}:\\d{2})\\s*[-~至–—]\\s*(\\d{1,2}:\\d{2})")
    private static let attendeeParenRegex = try? NSRegularExpression(pattern: "[（\\(][^）\\)]*[）\\)]")
    private static let attendeeIDRegex = try? NSRegularExpression(pattern: "\\d{3,}[\\*\\d]+[0-9Xx]?")

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
           let regex = condensedYearTitleRegex,
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
        guard let regex = timeSlotRegex,
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
        if let regex = attendeeParenRegex {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
        }
        for noise in ["居民身份证", "身份证", "港澳台居民居住证", "护照"] {
            s = s.replacingOccurrences(of: noise, with: "")
        }
        // 移除连续数字或脱敏号段
        if let regex = attendeeIDRegex {
            s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 辅助匹配规则

    private static func cleanVenueName(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^[•·◎\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\s>＞»→]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[📞\ue000-\uf8ff]+$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        guard t.count >= 2 else { return false }
        if isMetadataLine(t) { return false }
        if isDateOrTimeOnly(t) { return false }
        if t.hasSuffix("详情") || t.contains("详情页") || t.contains("电影票") || t.contains("门票") || t.contains("凭证") || t.contains("订单") || t.contains("取票") {
            return false
        }
        if t.contains("居民身份证") || t.contains("免费预约") || t.hasPrefix("¥") || t.hasPrefix("￥") {
            return false
        }
        if matchesRegex(t, pattern: "^[0-9]{4,6}[*xX×]{2,}[0-9Xx]{2,4}$") {
            return false
        }
        return true
    }

    private static func looksLikeMovieTicket(rawText: String) -> Bool {
        let markers = ["电影", "影城", "影院", "电影院", "影厅", "激光厅", "IMAX厅", "取电影票", "观影", "开场", "放映"]
        let markerCount = markers.filter { rawText.contains($0) }.count
        return markerCount >= 2 || rawText.contains("取电影票") || rawText.contains("观影") || (rawText.contains("影城") && rawText.contains("排") && rawText.contains("座"))
    }

    private static func parseMovieScreeningDate(from lines: [String], defaultYear: Int) -> Date? {
        let pattern = "(?:(20[2-3][0-9])[年./-])?([01]?[0-9])[月./-]([0-3]?[0-9])日?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let calendar = Calendar.current
        let time = lines.compactMap { line -> (Int, Int)? in
            guard let match = line.range(of: #"([01]?[0-9]|2[0-3]):([0-5][0-9])"#, options: .regularExpression) else { return nil }
            let value = String(line[match]).split(separator: ":").compactMap { Int($0) }
            guard value.count == 2 else { return nil }
            return (value[0], value[1])
        }.first ?? (16, 55)
        for line in lines {
            guard line.contains("今天") || line.contains("明天") || line.contains("月") || line.contains("/") || line.contains("-") else { continue }
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, range: nsRange),
               let mRange = Range(match.range(at: 2), in: line),
               let dRange = Range(match.range(at: 3), in: line),
               let month = Int(line[mRange]), let day = Int(line[dRange]) {
                let year: Int = {
                    guard match.range(at: 1).location != NSNotFound,
                          let yRange = Range(match.range(at: 1), in: line),
                          let year = Int(line[yRange]) else { return defaultYear }
                    return year
                }()
                var comps = DateComponents()
                comps.year = year; comps.month = month; comps.day = day; comps.hour = time.0; comps.minute = time.1
                if let date = calendar.date(from: comps) { return date }
            }
            if line.contains("今天") {
                return calendar.startOfDay(for: .now).addingTimeInterval(TimeInterval(time.0 * 3600 + time.1 * 60))
            }
            if line.contains("明天") {
                return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))?.addingTimeInterval(TimeInterval(time.0 * 3600 + time.1 * 60))
            }
        }
        return nil
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

    // MARK: - 火车票 / 机票截图专项解析（默认推测去车站/机场/地铁站接人，并预留提前量）

    private static func parseTravelTicketPickup(
        from sorted: [RecognizedLine],
        rawFullText: String,
        defaultYear: Int
    ) -> ImageTodoRecognitionResult? {
        // 排除顶部手机状态栏（如 17:23 电量信号栏）与底部系统导航栏
        let validLines = sorted.filter { $0.box.minY <= 0.92 && $0.box.maxY >= 0.04 }
        guard !validLines.isEmpty else { return nil }

        let trainMarkers = [
            "乘车人", "检票口", "座位号", "列车经停站", "复兴号", "和谐号", "智能动车",
            "变更到站", "乘车码", "12306", "二等座", "一等座", "商务座", "特等座",
            "硬卧", "软卧", "硬座", "无座", "终到", "车次详情", "列车担当"
        ]
        let flightMarkers = [
            "乘机人", "登机口", "值机", "航站楼", "行李转盘", "航班", "经济舱", "公务舱",
            "头等舱", "计划起飞", "预计到达", "计划到达", "实际到达", "电子客票", "到达口"
        ]

        let trainScore = trainMarkers.filter { rawFullText.contains($0) }.count
        let flightScore = flightMarkers.filter { rawFullText.contains($0) }.count

        let detectedTrainNo = Self.extractTrainNumber(from: validLines, rawText: rawFullText)
        let detectedFlightNo = Self.extractFlightNumber(from: validLines, rawText: rawFullText)

        let isTrainTicket = (trainScore >= 2) || (trainScore >= 1 && detectedTrainNo != nil)
        let isFlightTicket = !isTrainTicket && ((flightScore >= 2) || (flightScore >= 1 && detectedFlightNo != nil))

        guard isTrainTicket || isFlightTicket else { return nil }

        let isFlight = isFlightTicket
        let tripNumber = (isFlight ? detectedFlightNo : detectedTrainNo) ?? detectedTrainNo ?? detectedFlightNo ?? ""

        // 1. 提取票面乘车/乘机日期 (月、日、年)
        let cal = Calendar.current
        var ticketYear = defaultYear
        var ticketMonth = cal.component(.month, from: .now)
        var ticketDay = cal.component(.day, from: .now)

        let dateRegex = try? NSRegularExpression(pattern: "(?:(20[2-3][0-9])[年./-])?([01]?[0-9])[月./-]([0-3]?[0-9])日?")
        for line in validLines where line.box.minY >= 0.25 && line.box.maxY <= 0.88 {
            let t = line.text
            let nsRange = NSRange(location: 0, length: t.utf16.count)
            if let m = dateRegex?.firstMatch(in: t, range: nsRange),
               let mR = Range(m.range(at: 2), in: t),
               let dR = Range(m.range(at: 3), in: t),
               let month = Int(t[mR]), (1...12).contains(month),
               let day = Int(t[dR]), (1...31).contains(day) {
                if m.range(at: 1).location != NSNotFound,
                   let yR = Range(m.range(at: 1), in: t),
                   let y = Int(t[yR]) {
                    ticketYear = y
                }
                ticketMonth = month
                ticketDay = day
                break
            }
        }

        // 2. 提取出发时间、终到时间以及出发站、到达站
        struct TimeObs {
            var line: RecognizedLine
            var hour: Int
            var minute: Int
            var dayOffset: Int
        }

        let standaloneTimeRegex = try? NSRegularExpression(pattern: "^([0-2]?[0-9]):([0-5][0-9])(?:\\s*\\+?([12])天?)?$")
        let timeObsList: [TimeObs] = validLines.compactMap { line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(location: 0, length: t.utf16.count)
            guard let m = standaloneTimeRegex?.firstMatch(in: t, range: nsRange),
                  let hR = Range(m.range(at: 1), in: t),
                  let minR = Range(m.range(at: 2), in: t),
                  let h = Int(t[hR]), (0...23).contains(h),
                  let minute = Int(t[minR]), (0...59).contains(minute) else {
                return nil
            }
            var offset = 0
            if m.range(at: 3).location != NSNotFound,
               let offR = Range(m.range(at: 3), in: t),
               let offVal = Int(t[offR]) {
                offset = offVal
            }
            return TimeObs(line: line, hour: h, minute: minute, dayOffset: offset)
        }

        var depTime: (hour: Int, minute: Int)? = nil
        var arrTime: (hour: Int, minute: Int, dayOffset: Int)? = nil
        var departureStation: String? = nil
        var arrivalStation: String? = nil

        // 策略 A：主票面左右对称的 [出发时间 -> 到达时间] 行对（如 17:00 在左，21:18 在右）
        let leftTimes = timeObsList.filter { $0.line.box.minX < 0.36 && $0.line.box.minY > 0.38 }
        let rightTimes = timeObsList.filter { $0.line.box.minX > 0.58 && $0.line.box.minY > 0.38 }

        for lt in leftTimes {
            if let rt = rightTimes.first(where: { abs($0.line.box.midY - lt.line.box.midY) < 0.045 }) {
                depTime = (lt.hour, lt.minute)
                arrTime = (rt.hour, rt.minute, rt.dayOffset)

                // 在左侧时间正下方或正上方寻找出发站/机场名
                let leftStationCandidates = validLines.filter { cand in
                    cand.text != lt.line.text &&
                    cand.box.minX < 0.42 &&
                    abs(cand.box.midY - lt.line.box.midY) < 0.08
                }
                for cand in leftStationCandidates {
                    if let st = Self.cleanStationOrAirportName(cand.text), !st.isEmpty {
                        departureStation = st
                        break
                    }
                }

                // 在右侧时间正下方或正上方寻找终到站/机场名
                let rightStationCandidates = validLines.filter { cand in
                    cand.text != rt.line.text &&
                    cand.box.minX > 0.55 &&
                    abs(cand.box.midY - rt.line.box.midY) < 0.08
                }
                for cand in rightStationCandidates {
                    if let st = Self.cleanStationOrAirportName(cand.text), !st.isEmpty {
                        arrivalStation = st
                        break
                    }
                }
                break
            }
        }

        // 策略 B：经停站列表中的「终到」与「始发」垂直列兜底校验
        if let endMarker = validLines.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "终到" }) {
            let colLines = validLines.filter {
                abs($0.box.midX - endMarker.box.midX) < 0.12 &&
                $0.box.minY >= endMarker.box.minY &&
                $0.box.maxY <= endMarker.box.maxY + 0.09 &&
                $0.text != endMarker.text
            }
            for cl in colLines {
                if arrTime == nil,
                   let tm = timeObsList.first(where: { $0.line.text == cl.text && abs($0.line.box.midY - cl.box.midY) < 0.01 }) {
                    arrTime = (tm.hour, tm.minute, tm.dayOffset)
                } else if arrivalStation == nil,
                          let st = Self.cleanStationOrAirportName(cl.text) {
                    arrivalStation = st
                }
            }
        }

        if let startMarker = validLines.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "始发" }) {
            let colLines = validLines.filter {
                abs($0.box.midX - startMarker.box.midX) < 0.12 &&
                $0.box.minY >= startMarker.box.minY &&
                $0.box.maxY <= startMarker.box.maxY + 0.09 &&
                $0.text != startMarker.text
            }
            for cl in colLines {
                if depTime == nil,
                   let tm = timeObsList.first(where: { $0.line.text == cl.text && abs($0.line.box.midY - cl.box.midY) < 0.01 }) {
                    depTime = (tm.hour, tm.minute)
                } else if departureStation == nil,
                          let st = Self.cleanStationOrAirportName(cl.text) {
                    departureStation = st
                }
            }
        }

        // 若没有左右成对时间，但有至少 2 个独立时间点，取前两个分别作为出发与到达
        if arrTime == nil && timeObsList.count >= 2 {
            depTime = (timeObsList[0].hour, timeObsList[0].minute)
            arrTime = (timeObsList[1].hour, timeObsList[1].minute, timeObsList[1].dayOffset)
        } else if arrTime == nil, let singleTime = timeObsList.first {
            arrTime = (singleTime.hour, singleTime.minute, singleTime.dayOffset)
        }

        guard let finalArrTime = arrTime else { return nil }
        let finalArrivalStation = arrivalStation ?? (isFlight ? "机场航站楼" : "火车站")

        // 3. 提取乘车人/乘机人、座位号、检票口/登机口
        var passengerName: String? = nil
        var seatInfo: String? = nil
        var gateInfo: String? = nil

        let passengerRegex = try? NSRegularExpression(pattern: "(?:乘车人|乘机人|旅客|姓名)[：:\\s]*([^\\s·,，(（0-9]{2,10})")
        let seatRegex = try? NSRegularExpression(pattern: "(?:座位号|座位|席别|舱位)[：:\\s]*([^\\n]+)")
        let gateRegex = try? NSRegularExpression(pattern: "(?:检票口|登机口|到达口|行李转盘)[^：:]*[：:\\s]*([^\\n]+)")

        for line in validLines {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(location: 0, length: t.utf16.count)

            if passengerName == nil,
               let m = passengerRegex?.firstMatch(in: t, range: nsRange),
               let r = Range(m.range(at: 1), in: t) {
                passengerName = String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if seatInfo == nil,
               let m = seatRegex?.firstMatch(in: t, range: nsRange),
               let r = Range(m.range(at: 1), in: t) {
                seatInfo = String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if gateInfo == nil,
               let m = gateRegex?.firstMatch(in: t, range: nsRange),
               let r = Range(m.range(at: 1), in: t) {
                gateInfo = String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 4. 组装出发与终到 Date（若终到时间早于出发时间，自动顺延 +1 天处理跨夜车次/红眼航班）
        var depDate: Date? = nil
        if let dt = depTime {
            var depComps = DateComponents()
            depComps.year = ticketYear
            depComps.month = ticketMonth
            depComps.day = ticketDay
            depComps.hour = dt.hour
            depComps.minute = dt.minute
            depDate = cal.date(from: depComps)
        }

        var arrComps = DateComponents()
        arrComps.year = ticketYear
        arrComps.month = ticketMonth
        arrComps.day = ticketDay
        arrComps.hour = finalArrTime.hour
        arrComps.minute = finalArrTime.minute
        guard var arrDate = cal.date(from: arrComps) else { return nil }

        if finalArrTime.dayOffset > 0 {
            arrDate = cal.date(byAdding: .day, value: finalArrTime.dayOffset, to: arrDate) ?? arrDate
        } else if let dDate = depDate, arrDate < dDate {
            arrDate = cal.date(byAdding: .day, value: 1, to: arrDate) ?? arrDate
        }

        let pickupMeta = TravelPickupMetadata(
            isFlight: isFlight,
            tripNumber: tripNumber,
            passengerName: passengerName,
            departureStation: departureStation,
            arrivalStation: finalArrivalStation,
            departureAt: depDate,
            arrivalAt: arrDate,
            seatInfo: seatInfo,
            gateInfo: gateInfo,
            isPickupMode: true,
            destinationKind: .stationOrAirport,
            advanceMinutes: isFlight ? 45 : 30
        )

        return ImageTodoRecognitionResult(
            title: pickupMeta.resolvedTitle,
            type: .travelBooking,
            dueAt: pickupMeta.plannedTargetTime,
            station: pickupMeta.resolvedLocation,
            location: pickupMeta.resolvedLocation,
            pickupCode: nil,
            detail: pickupMeta.resolvedDetail,
            timeSlotText: nil,
            travelPickup: pickupMeta,
            rawText: rawFullText
        )
    }

    private static func extractTrainNumber(from lines: [RecognizedLine], rawText: String) -> String? {
        // 优先匹配 "G25列车经停站" 或 "G25次"
        if let regex = try? NSRegularExpression(pattern: "\\b([GDCZTKLYS][0-9]{1,4})(?:列车|次)"),
           let m = regex.firstMatch(in: rawText, range: NSRange(location: 0, length: rawText.utf16.count)),
           let r = Range(m.range(at: 1), in: rawText) {
            return String(rawText[r])
        }
        // 匹配独立车次行（如 "G25"）
        guard let lineRegex = try? NSRegularExpression(pattern: "^([GDCZTKLYS][0-9]{1,4})(?:\\s|$)") else { return nil }
        for line in lines where line.box.minY >= 0.35 && line.box.maxY <= 0.88 {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("检票口") || t.contains("座位") || t.contains("车") { continue }
            if let m = lineRegex.firstMatch(in: t, range: NSRange(location: 0, length: t.utf16.count)),
               let r = Range(m.range(at: 1), in: t) {
                return String(t[r])
            }
        }
        return nil
    }

    private static func extractFlightNumber(from lines: [RecognizedLine], rawText: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b([A-Z]{2}[0-9]{3,4}|[A-Z][0-9][0-9]{3,4}|[0-9][A-Z][0-9]{3,4})\\b") else {
            return nil
        }
        for line in lines where line.box.minY >= 0.30 && line.box.maxY <= 0.88 {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(location: 0, length: t.utf16.count)
            if let m = regex.firstMatch(in: t, range: nsRange),
               let r = Range(m.range(at: 1), in: t) {
                let candidate = String(t[r])
                if !candidate.hasPrefix("CR") && !candidate.hasPrefix("ID") {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func cleanStationOrAirportName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["始发", "终到", "始", "终", "出发", "到达"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for suffix in [">", "〉", "》", "›", "→"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard s.count >= 2, s.count <= 14 else { return nil }
        let rejectWords = [
            "历时", "小时", "分钟", "乘车", "检票", "座位", "改签", "退票", "变更",
            "复兴号", "和谐号", "动车", "优惠", "立减", "金融", "领取", "服务",
            "日历", "详情", "停留", "始发", "终到", "周日", "周一", "周二", "周三", "周四", "周五", "周六"
        ]
        if rejectWords.contains(where: { s.contains($0) }) { return nil }
        if isDateOrTimeOnly(s) { return nil }
        if matchesRegex(s, pattern: "^[0-9A-Za-z¥￥.\\-+]+$") { return nil }
        return s
    }

    private static func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// 火车票 / 机票截图接人时间提前量与汇合地点（火车站/机场/地铁站）配置面板
public struct TravelTicketPickupConfigView: View {
    @Binding public var pickup: TravelPickupMetadata

    private let advancePresets = [15, 30, 45, 60, 90, 0]

    public init(pickup: Binding<TravelPickupMetadata>) {
        self._pickup = pickup
    }

    private var subwayQuickSuggestions: [String] {
        let base = pickup.arrivalStation.replacingOccurrences(of: "站", with: "")
        return [
            "\(base)地铁站",
            "\(base)站地铁口",
            "市中心换乘地铁站"
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 识别到的票面行程横幅
            HStack(spacing: 10) {
                Image(systemName: pickup.isFlight ? "airplane.arrival" : "train.side.front.car")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(Color.blue.gradient)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pickup.tripNumber.isEmpty ? (pickup.isFlight ? "航班行程" : "高铁/火车票") : pickup.tripNumber)
                            .font(.subheadline.bold())
                        Text("\(pickup.departureStation ?? "始发") → \(pickup.arrivalStation)")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    HStack(spacing: 6) {
                        Text("终到：\(pickup.arrivalAt.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let p = pickup.passengerName, !p.isEmpty {
                            Text("· 乘\(pickup.isFlight ? "机" : "车")人：\(p)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // 2. 推测意图：去接人（默认） vs 本人出行
            VStack(alignment: .leading, spacing: 6) {
                Text("行程用途（上传他人车票/机票默认推测为去接人）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("行程用途", selection: $pickup.isPickupMode) {
                    Text("🚗 去接人（按到站时间）").tag(true)
                    Text("🧳 本人乘车/乘机").tag(false)
                }
                .pickerStyle(.segmented)
            }

            // 3. 到机场 / 火车站 / 某个地铁站的地点选择
            if pickup.isPickupMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接人汇合地点（火车站 / 机场 / 某个地铁站）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("汇合地点类型", selection: $pickup.destinationKind) {
                        ForEach(TravelPickupDestinationKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if pickup.destinationKind == .subwayStation {
                        HStack(spacing: 6) {
                            Image(systemName: "tram.fill.tunnel")
                                .foregroundStyle(.teal)
                            TextField("输入要去的地铁站（如：上海虹桥地铁站、人民广场地铁站）", text: $pickup.subwayStationName)
                                .font(.subheadline)
                        }
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(subwayQuickSuggestions, id: \.self) { sug in
                                    Button {
                                        pickup.subwayStationName = sug
                                        Haptic.selection()
                                    } label: {
                                        Text(sug)
                                            .font(.caption2)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule().fill(pickup.subwayStationName == sug ? Color.teal.opacity(0.18) : Color(.tertiarySystemFill))
                                            )
                                            .foregroundStyle(pickup.subwayStationName == sug ? .teal : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else if pickup.destinationKind == .customSpot {
                        HStack(spacing: 6) {
                            Image(systemName: "car.fill")
                                .foregroundStyle(.orange)
                            TextField("输入具体上客点（如：P9停车场、T2到达层4号门）", text: $pickup.customSpotName)
                                .font(.subheadline)
                        }
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                    }
                }
            }

            // 4. 到站/到地铁站的时间提前量设置
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pickup.isPickupMode ? "到\(pickup.resolvedLocation)的时间提前量" : "提前到站候车余量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("计划 \(pickup.plannedTargetTime.formatted(date: .omitted, time: .shortened)) 到达")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(advancePresets, id: \.self) { mins in
                            let isSelected = pickup.advanceMinutes == mins
                            Button {
                                pickup.advanceMinutes = mins
                                Haptic.selection()
                            } label: {
                                Text(mins == 0 ? "准点 (\(pickup.baseTicketTime.formatted(date: .omitted, time: .shortened)))" : "提前 \(mins) 分钟")
                                    .font(.caption.weight(isSelected ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(isSelected ? Color.blue : Color(.tertiarySystemFill))
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Stepper(
                    value: $pickup.advanceMinutes,
                    in: 0...240,
                    step: 5
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.blue)
                        if pickup.advanceMinutes > 0 {
                            Text("比\(pickup.isPickupMode ? "到站" : "发车")时间提前 **\(pickup.advanceMinutes) 分钟**（\(pickup.plannedTargetTime.formatted(date: .omitted, time: .shortened))）")
                                .font(.caption)
                        } else {
                            Text("不设提前量，按票面时间（\(pickup.baseTicketTime.formatted(date: .omitted, time: .shortened))）")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

public enum OCRError: LocalizedError {
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return L10n.tr("无效的图片格式或无法读取图像数据")
        }
    }
}
