import Foundation
import SwiftData
import SwiftUI

/// 跨模块搜索分类定义
public enum UnifiedSearchCategory: String, CaseIterable, Identifiable, Sendable {
    case todo = "待办事项"
    case expense = "账目明细"
    case storage = "收纳物品"
    case document = "证件卡包"
    case memo = "语音备忘"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .todo: return "checkmark.circle.fill"
        case .expense: return "yensign.circle.fill"
        case .storage: return "archivebox.fill"
        case .document: return "person.text.rectangle.fill"
        case .memo: return "mic.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .todo: return .blue
        case .expense: return .orange
        case .storage: return .indigo
        case .document: return .purple
        case .memo: return .teal
        }
    }
}

/// 统一搜索结果条目
public struct UnifiedSearchResultItem: Identifiable, Sendable {
    public let id: UUID
    public let category: UnifiedSearchCategory
    public let title: String
    public let subtitle: String?
    public let date: Date?
    public let isSensitive: Bool
    public let targetTab: NavigationRouter.AppTab
    public let vaultDestination: String?

    public init(
        id: UUID,
        category: UnifiedSearchCategory,
        title: String,
        subtitle: String?,
        date: Date?,
        isSensitive: Bool,
        targetTab: NavigationRouter.AppTab,
        vaultDestination: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.isSensitive = isSensitive
        self.targetTab = targetTab
        self.vaultDestination = vaultDestination
    }
}

/// 跨模块搜索结果的统一隐私闸门：锁定态或「敏感详情」开关关闭时，五类结果一律只保留标题类字段与所属模块
enum SearchPrivacyGate {
    /// 复用现有状态：AppLock 锁定标记 + 原只作用于通知的「敏感详情」开关存储键，不新造设置项
    @MainActor static var hidesSensitiveDetails: Bool {
        AppLockManager.shared.isLocked || !TodoNotificationManager.shared.showSensitiveDetails
    }

    /// 结果暴露的唯一出口：隐藏态一律清空副标题，避免证件与其他模块两套脱敏口径
    @MainActor static func reveal(
        category: UnifiedSearchCategory,
        title: String,
        maskedTitle: String? = nil,
        subtitle: String?
    ) -> (title: String, subtitle: String?) {
        guard hidesSensitiveDetails else { return (title, subtitle) }
        // 证件标题可能含持证人姓名，隐藏态回退为证件类型名
        if category == .document, let maskedTitle {
            return ("🔒 \(maskedTitle)", nil)
        }
        return (title, nil)
    }
}

/// 跨模块统一搜索服务（扇出 TodoItem / ExpenseRecord / StoredItem / IDDocumentItem / VoiceMemo）
@MainActor
public final class UnifiedSearchService: ObservableObject {
    public static let shared = UnifiedSearchService()

    @Published public var searchText: String = ""
    @Published public var results: [UnifiedSearchResultItem] = []
    @Published public var isSearching: Bool = false

    private init() {}

    /// 执行跨模块全量检索，敏感暴露级别统一由 SearchPrivacyGate 判定
    public func search(query: String, context: ModelContext) async -> [UnifiedSearchResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.results = []
            return []
        }

        isSearching = true
        defer { isSearching = false }

        var items: [UnifiedSearchResultItem] = []

        // 1. 待办事项 (TodoItem)
        var todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> {
                $0.title.localizedStandardContains(trimmed) ||
                ($0.detail != nil && $0.detail!.localizedStandardContains(trimmed)) ||
                ($0.location != nil && $0.location!.localizedStandardContains(trimmed)) ||
                ($0.station != nil && $0.station!.localizedStandardContains(trimmed)) ||
                ($0.pickupCode != nil && $0.pickupCode!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        todoDescriptor.fetchLimit = 20
        if let todos = try? context.fetch(todoDescriptor) {
            for t in todos {
                let sub: String? = {
                    if let code = t.pickupCode, !code.isEmpty {
                        let stationText = t.station ?? t.location ?? ""
                        return "取件码：\(code) · \(stationText)"
                    }
                    return t.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? t.detail : (t.station ?? t.location)
                }()
                let revealed = SearchPrivacyGate.reveal(category: .todo, title: t.title, subtitle: sub)
                items.append(
                    UnifiedSearchResultItem(
                        id: t.id,
                        category: .todo,
                        title: revealed.title,
                        subtitle: revealed.subtitle,
                        date: t.dueAt ?? t.createdAt,
                        isSensitive: true,
                        targetTab: .todos,
                        vaultDestination: nil
                    )
                )
            }
        }

        // 2. 记账记录 (ExpenseRecord)
        var expenseDescriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate<ExpenseRecord> {
                $0.title.localizedStandardContains(trimmed) ||
                $0.categoryRaw.localizedStandardContains(trimmed) ||
                $0.rawText.localizedStandardContains(trimmed)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        expenseDescriptor.fetchLimit = 20
        if let expenses = try? context.fetch(expenseDescriptor) {
            for e in expenses {
                let sign = e.isIncome ? "+" : "-"
                let amountText = String(format: "%@%.2f 元", sign, e.amount)
                let revealed = SearchPrivacyGate.reveal(
                    category: .expense,
                    title: e.title,
                    subtitle: "\(amountText) · \(e.categoryRaw)"
                )
                items.append(
                    UnifiedSearchResultItem(
                        id: e.id,
                        category: .expense,
                        title: revealed.title,
                        subtitle: revealed.subtitle,
                        date: e.date,
                        isSensitive: true,
                        targetTab: .expenses,
                        vaultDestination: nil
                    )
                )
            }
        }

        // 3. 收纳物品 (StoredItem)
        var storageDescriptor = FetchDescriptor<StoredItem>(
            predicate: #Predicate<StoredItem> {
                $0.name.localizedStandardContains(trimmed) ||
                $0.location.localizedStandardContains(trimmed) ||
                $0.roomArea.localizedStandardContains(trimmed) ||
                ($0.notes != nil && $0.notes!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        storageDescriptor.fetchLimit = 20
        if let stored = try? context.fetch(storageDescriptor) {
            for s in stored {
                let loc = "\(s.roomArea) · \(s.location)"
                let revealed = SearchPrivacyGate.reveal(category: .storage, title: s.name, subtitle: loc)
                items.append(
                    UnifiedSearchResultItem(
                        id: s.id,
                        category: .storage,
                        title: revealed.title,
                        subtitle: revealed.subtitle,
                        date: s.updatedAt,
                        isSensitive: true,
                        targetTab: .vault,
                        vaultDestination: "storage"
                    )
                )
            }
        }

        // 4. 证件卡包 (IDDocumentItem) - 脱敏口径统一走 SearchPrivacyGate
        // 锁定态或隐藏敏感详情时，禁止通过搜索词探测持有人姓名与证件号码（消除侧信道枚举泄漏）
        let docPredicate: Predicate<IDDocumentItem>
        if SearchPrivacyGate.hidesSensitiveDetails {
            docPredicate = #Predicate<IDDocumentItem> {
                $0.title.localizedStandardContains(trimmed) ||
                $0.typeRaw.localizedStandardContains(trimmed)
            }
        } else {
            docPredicate = #Predicate<IDDocumentItem> {
                $0.title.localizedStandardContains(trimmed) ||
                $0.typeRaw.localizedStandardContains(trimmed) ||
                ($0.holderName != nil && $0.holderName!.localizedStandardContains(trimmed)) ||
                ($0.documentNumber != nil && $0.documentNumber!.localizedStandardContains(trimmed))
            }
        }
        var docDescriptor = FetchDescriptor<IDDocumentItem>(
            predicate: docPredicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        docDescriptor.fetchLimit = 15
        if let docs = try? context.fetch(docDescriptor) {
            for d in docs {
                let subtitleText: String? = {
                    if let num = d.documentNumber, !num.isEmpty {
                        return "\(d.type.displayName) · 号码：\(num)"
                    }
                    return d.type.displayName
                }()
                let revealed = SearchPrivacyGate.reveal(
                    category: .document,
                    title: d.title,
                    maskedTitle: d.type.displayName,
                    subtitle: subtitleText
                )
                items.append(
                    UnifiedSearchResultItem(
                        id: d.id,
                        category: .document,
                        title: revealed.title,
                        subtitle: revealed.subtitle,
                        date: d.expiryDate ?? d.updatedAt,
                        isSensitive: true,
                        targetTab: .documents,
                        vaultDestination: "documents"
                    )
                )
            }
        }

        // 5. 语音备忘 (VoiceMemo)
        var memoDescriptor = FetchDescriptor<VoiceMemo>(
            predicate: #Predicate<VoiceMemo> {
                $0.title.localizedStandardContains(trimmed) ||
                ($0.transcription != nil && $0.transcription!.localizedStandardContains(trimmed)) ||
                ($0.summary != nil && $0.summary!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        memoDescriptor.fetchLimit = 15
        if let memos = try? context.fetch(memoDescriptor) {
            for m in memos {
                let snippet = (m.summary ?? m.transcription ?? "").prefix(40)
                let sub = snippet.isEmpty ? "\(Int(m.duration)) 秒录音" : String(snippet)
                let revealed = SearchPrivacyGate.reveal(category: .memo, title: m.title, subtitle: sub)
                items.append(
                    UnifiedSearchResultItem(
                        id: m.id,
                        category: .memo,
                        title: revealed.title,
                        subtitle: revealed.subtitle,
                        date: m.createdAt,
                        isSensitive: true,
                        targetTab: .memos,
                        vaultDestination: "voiceMemos"
                    )
                )
            }
        }

        self.results = items
        return items
    }
}
