import Foundation
import UIKit

/// 面对面碰一碰与二维码分享的数据载荷类型
public enum SharePayloadType: String, Codable, CaseIterable, Sendable {
    case todos = "todos"                   // 待办/清单打包
    case expenseAA = "expense_aa"           // AA 账单分摊
    case parcelTransfer = "parcel_transfer" // 快递取件码转交
    case emotionPulse = "emotion_pulse"     // 心情名片 / 情绪共振
    case storageItem = "storage_item"       // 物品收纳位置备忘

    public var displayName: String {
        switch self {
        case .todos: return "待办清单"
        case .expenseAA: return "AA 账单分摊"
        case .parcelTransfer: return "快递代取转交"
        case .emotionPulse: return "心情名片共振"
        case .storageItem: return "物品收纳位置"
        }
    }

    public var systemIcon: String {
        switch self {
        case .todos: return "checklist"
        case .expenseAA: return "yensign.circle.fill"
        case .parcelTransfer: return "shippingbox.fill"
        case .emotionPulse: return "heart.circle.fill"
        case .storageItem: return "archivebox.fill"
        }
    }
}

/// 面对面 AA 账单载荷
public struct SharedExpenseAADTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String                // 消费项目/描述，如 "老四川火锅"
    public var totalAmount: Double          // 账单总金额，如 300.0
    public var splitAmount: Double          // 本人/每人分摊金额，如 100.0
    public var splitCount: Int              // 平摊总人数，如 3
    public var categoryRaw: String          // 消费类别 ExpenseCategory.rawValue
    public var date: Date                   // 消费时间
    public var note: String?                // 备注留言，如 "聚餐分摊"

    public init(
        id: UUID = UUID(),
        title: String,
        totalAmount: Double,
        splitAmount: Double,
        splitCount: Int = 2,
        categoryRaw: String = "餐饮美食",
        date: Date = .now,
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.totalAmount = totalAmount
        self.splitAmount = splitAmount
        self.splitCount = max(splitCount, 1)
        self.categoryRaw = categoryRaw
        self.date = date
        self.note = note
    }
}

/// 面对面快递代取转交载荷
public struct SharedParcelDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String                // 包裹/物品描述，如 "天猫生鲜"
    public var pickupCode: String           // 取件码，如 "3-2-4012"
    public var station: String?             // 驿站地址/名称，如 "南门菜鸟驿站"
    public var courier: String?             // 快递公司，如 "顺丰速运"
    public var dueAt: Date?                 // 逾期时间
    public var urgentNote: String?          // 代取附言，如 "顺路帮我拿下放门口，谢谢！"

    public init(
        id: UUID = UUID(),
        title: String,
        pickupCode: String,
        station: String? = nil,
        courier: String? = nil,
        dueAt: Date? = nil,
        urgentNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.pickupCode = pickupCode
        self.station = station
        self.courier = courier
        self.dueAt = dueAt
        self.urgentNote = urgentNote
    }
}

/// 面对面心情名片 / 情绪共振载荷
public struct SharedEmotionDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var moodScore: Int               // 1..5 心情指数
    public var energyScore: Int             // 1..5 精力充沛度
    public var stressScore: Int             // 1..5 压力水平
    public var moodTag: String              // 如 "平静放松", "充满干劲", "有些疲倦"
    public var note: String?                // 随想微笔记
    public var date: Date                   // 记录时间

    public init(
        id: UUID = UUID(),
        moodScore: Int,
        energyScore: Int,
        stressScore: Int,
        moodTag: String = "",
        note: String? = nil,
        date: Date = .now
    ) {
        self.id = id
        self.moodScore = moodScore
        self.energyScore = energyScore
        self.stressScore = stressScore
        self.moodTag = moodTag
        self.note = note
        self.date = date
    }
}

/// 面对面物品收纳位置共享载荷
public struct SharedStorageDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String                // 物品名称
    public var roomArea: String            // 所在房间/区域
    public var location: String            // 详细位置
    public var notes: String?              // 补充备注

    public init(
        id: UUID = UUID(),
        name: String,
        roomArea: String,
        location: String,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.roomArea = roomArea
        self.location = location
        self.notes = notes
    }
}

/// 统一离线分享信封包（碰一碰与二维码通用）
public struct UniversalShareEnvelope: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var version: Int                 // 协议版本号，当前为 2
    public var senderName: String           // 发送方设备名或昵称，如 "张三的 iPhone"
    public var type: SharePayloadType       // 业务载荷类型
    public var title: String                // 标题概要
    public var createdAt: Date              // 发送时间戳

    // 具体载荷（按 type 互斥）
    public var todos: [SharedTodoDTO]?
    public var expenseAA: SharedExpenseAADTO?
    public var parcel: SharedParcelDTO?
    public var emotion: SharedEmotionDTO?
    public var storage: SharedStorageDTO?

    public init(
        id: UUID = UUID(),
        version: Int = 2,
        senderName: String = UIDevice.current.name,
        type: SharePayloadType,
        title: String,
        createdAt: Date = .now,
        todos: [SharedTodoDTO]? = nil,
        expenseAA: SharedExpenseAADTO? = nil,
        parcel: SharedParcelDTO? = nil,
        emotion: SharedEmotionDTO? = nil,
        storage: SharedStorageDTO? = nil
    ) {
        self.id = id
        self.version = version
        self.senderName = senderName
        self.type = type
        self.title = title
        self.createdAt = createdAt
        self.todos = todos
        self.expenseAA = expenseAA
        self.parcel = parcel
        self.emotion = emotion
        self.storage = storage
    }

    // MARK: - 序列化与 URL Scheme 封装

    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public func encodeToURLString() -> String {
        switch type {
        case .expenseAA:
            if let aa = expenseAA {
                var comp = URLComponents()
                comp.scheme = "assistant"
                comp.host = "share"
                var queryItems: [URLQueryItem] = [
                    URLQueryItem(name: "t", value: "aa"),
                    URLQueryItem(name: "ti", value: aa.title),
                    URLQueryItem(name: "a", value: String(format: "%.2f", aa.splitAmount).replacingOccurrences(of: ".00", with: "")),
                    URLQueryItem(name: "tot", value: String(format: "%.2f", aa.totalAmount).replacingOccurrences(of: ".00", with: "")),
                    URLQueryItem(name: "c", value: "\(aa.splitCount)")
                ]
                if !aa.categoryRaw.isEmpty {
                    queryItems.append(URLQueryItem(name: "cat", value: aa.categoryRaw))
                }
                comp.queryItems = queryItems
                if let urlStr = comp.url?.absoluteString {
                    return urlStr
                }
            }

        case .parcelTransfer:
            if let p = parcel {
                var comp = URLComponents()
                comp.scheme = "assistant"
                comp.host = "share"
                var queryItems: [URLQueryItem] = [
                    URLQueryItem(name: "t", value: "parcel"),
                    URLQueryItem(name: "ti", value: p.title),
                    URLQueryItem(name: "code", value: p.pickupCode)
                ]
                if let st = p.station, !st.isEmpty {
                    queryItems.append(URLQueryItem(name: "st", value: st))
                }
                if let cr = p.courier, !cr.isEmpty {
                    queryItems.append(URLQueryItem(name: "cr", value: cr))
                }
                if let note = p.urgentNote, !note.isEmpty {
                    queryItems.append(URLQueryItem(name: "note", value: note))
                }
                comp.queryItems = queryItems
                if let urlStr = comp.url?.absoluteString {
                    return urlStr
                }
            }

        case .emotionPulse:
            if let emo = emotion {
                var comp = URLComponents()
                comp.scheme = "assistant"
                comp.host = "share"
                var queryItems: [URLQueryItem] = [
                    URLQueryItem(name: "t", value: "mood"),
                    URLQueryItem(name: "m", value: "\(emo.moodScore)"),
                    URLQueryItem(name: "e", value: "\(emo.energyScore)"),
                    URLQueryItem(name: "s", value: "\(emo.stressScore)")
                ]
                if !emo.moodTag.isEmpty {
                    queryItems.append(URLQueryItem(name: "tag", value: emo.moodTag))
                }
                if let note = emo.note, !note.isEmpty {
                    queryItems.append(URLQueryItem(name: "note", value: note))
                }
                comp.queryItems = queryItems
                if let urlStr = comp.url?.absoluteString {
                    return urlStr
                }
            }

        case .storageItem:
            if let st = storage {
                var comp = URLComponents()
                comp.scheme = "assistant"
                comp.host = "share"
                var queryItems: [URLQueryItem] = [
                    URLQueryItem(name: "t", value: "storage"),
                    URLQueryItem(name: "name", value: st.name),
                    URLQueryItem(name: "area", value: st.roomArea),
                    URLQueryItem(name: "loc", value: st.location)
                ]
                if let note = st.notes, !note.isEmpty {
                    queryItems.append(URLQueryItem(name: "note", value: note))
                }
                comp.queryItems = queryItems
                if let urlStr = comp.url?.absoluteString {
                    return urlStr
                }
            }

        case .todos:
            if let items = todos, !items.isEmpty {
                // 如果只包含简易待办标题（无复杂时间/取件码等），生成紧凑型短 URL
                let simpleTitles = items.compactMap { (item: SharedTodoDTO) -> String? in
                    if item.d == nil && item.pc == nil && item.loc == nil && item.due == nil {
                        return item.t.replacingOccurrences(of: ",", with: "，")
                    }
                    return nil
                }
                if simpleTitles.count == items.count && items.count <= 6 {
                    var comp = URLComponents()
                    comp.scheme = "assistant"
                    comp.host = "share"
                    comp.queryItems = [
                        URLQueryItem(name: "t", value: "todos"),
                        URLQueryItem(name: "ti", value: title),
                        URLQueryItem(name: "items", value: simpleTitles.joined(separator: ","))
                    ]
                    if let urlStr = comp.url?.absoluteString {
                        return urlStr
                    }
                }
            }
        }

        // 回退到 base64 封装
        guard let data = encode() else { return "assistant://share" }
        let base64 = data.base64EncodedString()
        if let encoded = base64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return "assistant://share?d=\(encoded)"
        }
        return "assistant://share?d=\(base64)"
    }

    /// 生成适合微信/社交聊天的离线口令文案
    public func generateShareText() -> String {
        let link = encodeToURLString()
        switch type {
        case .todos:
            let count = todos?.count ?? 0
            return "【小助清单】向你分享了「\(title)」共 \(count) 项待办事宜！\n复制本条消息并打开小助 App 即可一键同步：\n\(link)"
        case .expenseAA:
            if let aa = expenseAA {
                return "【小助AA记账】向你分享了「\(aa.title)」AA 账单，你的分摊金额为 ¥\(String(format: "%.2f", aa.splitAmount))（\(aa.splitCount) 人平摊）！\n复制本条消息并打开小助 App 即可一键记入本地账本：\n\(link)"
            }
            return "【小助AA记账】向你分享了 AA 账单！\n复制本条消息并打开小助 App 即可查看导入：\n\(link)"
        case .parcelTransfer:
            if let p = parcel {
                return "【小助快递代取】请顺路帮我代取快递「\(p.title)」取件码 [\(p.pickupCode)]！\n复制本条消息并打开小助 App 即可直登灵动岛与小组件：\n\(link)"
            }
            return "【小助快递代取】向你转交了快递取件码！\n复制本条消息并打开小助 App 即可查看导入：\n\(link)"
        case .emotionPulse:
            return "【小助心情共振】向你分享了今日情绪状态名片！\n复制本条消息并打开小助 App 即可查看双方今日情绪共振：\n\(link)"
        case .storageItem:
            if let st = storage {
                return "【小助物品收纳】「\(st.name)」存放在「\(st.roomArea) · \(st.location)」！\n复制本条消息并打开小助 App 即可一键同步至本地收纳库：\n\(link)"
            }
            return "【小助物品收纳】向你共享了物品存放位置！\n复制本条消息并打开小助 App 即可查看同步：\n\(link)"
        }
    }

    public static func decode(from data: Data) -> UniversalShareEnvelope? {
        try? JSONDecoder().decode(UniversalShareEnvelope.self, from: data)
    }

    public static func decode(from rawString: String) -> UniversalShareEnvelope? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0. 若文本中嵌入了 assistant:// 链接，优先提取出 URL
        if let match = trimmed.range(of: #"assistant://[^\s\n\r\t"'\<\>]+"#, options: .regularExpression) {
            let matchedURL = String(trimmed[match])
            if let env = decodeURL(matchedURL) {
                return env
            }
        }

        // 1. 如果整段本身就是 URL
        if let env = decodeURL(trimmed) {
            return env
        }

        // 2. 尝试当成纯 base64 字符串解析
        var base64Content = trimmed
        if let decodedStr = base64Content.removingPercentEncoding {
            base64Content = decodedStr
        }

        if let data = Data(base64Encoded: base64Content) {
            if let env = try? JSONDecoder().decode(UniversalShareEnvelope.self, from: data) {
                return env
            }
        }

        // 3. 尝试当成纯 JSON 字符串解析
        if let data = trimmed.data(using: .utf8) {
            if let env = try? JSONDecoder().decode(UniversalShareEnvelope.self, from: data) {
                return env
            }
        }

        return nil
    }

    private static func decodeURL(_ urlString: String) -> UniversalShareEnvelope? {
        var comp = URLComponents(string: urlString)
        if comp == nil, let percentEncoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            comp = URLComponents(string: percentEncoded)
        }
        guard let components = comp, let scheme = components.scheme?.lowercased(), scheme == "assistant" else {
            return nil
        }

        // 优先检查是否有 d= 或 data= 参数（兼顾旧版全量数据与大容量待办）
        if let dParam = components.queryItems?.first(where: { $0.name == "d" || $0.name == "data" })?.value {
            var rawBase64 = dParam
            if let unescaped = rawBase64.removingPercentEncoding {
                rawBase64 = unescaped
            }
            if let data = Data(base64Encoded: rawBase64),
               let env = try? JSONDecoder().decode(UniversalShareEnvelope.self, from: data) {
                return env
            }
        }

        // 紧凑短 URL 格式：根据 t 或 type 判断
        guard let typeStr = components.queryItems?.first(where: { $0.name == "t" || $0.name == "type" })?.value else {
            return nil
        }

        func queryVal(_ key: String) -> String? {
            components.queryItems?.first(where: { $0.name == key })?.value
        }

        switch typeStr.lowercased() {
        case "aa", "expense_aa", "expense":
            let title = queryVal("ti") ?? queryVal("title") ?? "AA 账单"
            let splitAmount = Double(queryVal("a") ?? queryVal("amount") ?? "0") ?? 0
            let totalAmount = Double(queryVal("tot") ?? queryVal("total") ?? "\(splitAmount * 2)") ?? (splitAmount * 2)
            let splitCount = Int(queryVal("c") ?? queryVal("count") ?? "2") ?? 2
            let category = queryVal("cat") ?? queryVal("category") ?? "餐饮"
            let note = queryVal("note") ?? "AA 分摊"

            let aaDTO = SharedExpenseAADTO(
                title: title,
                totalAmount: totalAmount,
                splitAmount: splitAmount,
                splitCount: splitCount,
                categoryRaw: category,
                date: .now,
                note: note
            )
            return UniversalShareEnvelope(
                type: .expenseAA,
                title: "AA 记账: \(title)",
                expenseAA: aaDTO
            )

        case "parcel", "parcel_transfer", "pkg":
            let title = queryVal("ti") ?? queryVal("title") ?? "快递包裹"
            let pickupCode = queryVal("code") ?? queryVal("pc") ?? ""
            let station = queryVal("st") ?? queryVal("station")
            let courier = queryVal("cr") ?? queryVal("courier")
            let urgentNote = queryVal("note")

            let parcelDTO = SharedParcelDTO(
                title: title,
                pickupCode: pickupCode,
                station: station,
                courier: courier,
                dueAt: nil,
                urgentNote: urgentNote
            )
            return UniversalShareEnvelope(
                type: .parcelTransfer,
                title: "快递代取: \(title)",
                parcel: parcelDTO
            )

        case "mood", "emotion", "pulse":
            let moodScore = Int(queryVal("m") ?? queryVal("mood") ?? "3") ?? 3
            let energyScore = Int(queryVal("e") ?? queryVal("energy") ?? "3") ?? 3
            let stressScore = Int(queryVal("s") ?? queryVal("stress") ?? "2") ?? 2
            let tag = queryVal("tag") ?? "平和"
            let note = queryVal("note")

            let emotionDTO = SharedEmotionDTO(
                moodScore: moodScore,
                energyScore: energyScore,
                stressScore: stressScore,
                moodTag: tag,
                note: note,
                date: .now
            )
            return UniversalShareEnvelope(
                type: .emotionPulse,
                title: "心情名片",
                emotion: emotionDTO
            )

        case "todo", "todos":
            let title = queryVal("ti") ?? queryVal("title") ?? "待办事项"
            if let itemsStr = queryVal("items") {
                let titles = itemsStr.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let dtos = titles.map { SharedTodoDTO(title: $0, type: "general") }
                return UniversalShareEnvelope(
                    type: .todos,
                    title: title,
                    todos: dtos
                )
            }
            return nil

        case "storage", "storage_item", "item":
            let name = queryVal("name") ?? queryVal("ti") ?? "物品"
            let area = queryVal("area") ?? "主卧"
            let loc = queryVal("loc") ?? queryVal("location") ?? ""
            let note = queryVal("note")

            let dto = SharedStorageDTO(
                name: name,
                roomArea: area,
                location: loc,
                notes: note
            )
            return UniversalShareEnvelope(
                type: .storageItem,
                title: "物品收纳: \(name)",
                storage: dto
            )

        default:
            return nil
        }
    }

    // MARK: - 便捷构造器

    /// 从 StoredItem 构造物品收纳位置信封
    public static func forStorage(
        item: StoredItem,
        senderName: String = UIDevice.current.name
    ) -> UniversalShareEnvelope {
        let dto = SharedStorageDTO(
            name: item.name,
            roomArea: item.roomArea,
            location: item.location,
            notes: item.notes
        )
        return UniversalShareEnvelope(
            senderName: senderName,
            type: .storageItem,
            title: "物品收纳: \(item.name)",
            storage: dto
        )
    }

    /// 从 TodoItem 数组构造待办清单信封
    static func forTodos(
        title: String,
        todos: [TodoItem],
        senderName: String = UIDevice.current.name
    ) -> UniversalShareEnvelope {
        let dtos = todos.map { item in
            SharedTodoDTO(
                title: item.title,
                type: item.typeRaw,
                detail: item.detail,
                pickupCode: item.pickupCode,
                location: item.location ?? item.station,
                courier: item.courier,
                due: item.dueAt
            )
        }
        return UniversalShareEnvelope(
            senderName: senderName,
            type: .todos,
            title: title,
            todos: dtos
        )
    }

    /// 从快递事项构造单独的快递转交代办信封
    static func forParcel(
        item: TodoItem,
        urgentNote: String? = nil,
        senderName: String = UIDevice.current.name
    ) -> UniversalShareEnvelope {
        let parcelDTO = SharedParcelDTO(
            title: item.title,
            pickupCode: item.pickupCode ?? "",
            station: item.location ?? item.station,
            courier: item.courier,
            dueAt: item.dueAt,
            urgentNote: urgentNote
        )
        return UniversalShareEnvelope(
            senderName: senderName,
            type: .parcelTransfer,
            title: "快递代取: \(item.title)",
            parcel: parcelDTO
        )
    }

    /// 构造 AA 记账分摊信封
    public static func forExpenseAA(
        record: ExpenseRecord,
        splitCount: Int,
        splitAmount: Double? = nil,
        note: String? = nil,
        senderName: String = UIDevice.current.name
    ) -> UniversalShareEnvelope {
        let count = max(splitCount, 1)
        let amount = splitAmount ?? (record.amount / Double(count))
        let dto = SharedExpenseAADTO(
            id: record.id,
            title: record.title,
            totalAmount: record.amount,
            splitAmount: (amount * 100).rounded() / 100,
            splitCount: count,
            categoryRaw: record.categoryRaw,
            date: record.date,
            note: note ?? "AA 聚餐分摊"
        )
        return UniversalShareEnvelope(
            senderName: senderName,
            type: .expenseAA,
            title: "AA 记账: \(record.title)",
            expenseAA: dto
        )
    }

    /// 构造情绪共振名片信封
    public static func forEmotion(
        moodScore: Int,
        energyScore: Int,
        stressScore: Int,
        moodTag: String = "",
        note: String? = nil,
        senderName: String = UIDevice.current.name
    ) -> UniversalShareEnvelope {
        let dto = SharedEmotionDTO(
            moodScore: moodScore,
            energyScore: energyScore,
            stressScore: stressScore,
            moodTag: moodTag,
            note: note,
            date: .now
        )
        return UniversalShareEnvelope(
            senderName: senderName,
            type: .emotionPulse,
            title: "\(senderName) 的今日心情名片",
            emotion: dto
        )
    }
}
