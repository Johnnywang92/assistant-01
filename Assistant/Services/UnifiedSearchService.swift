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

/// 跨模块统一搜索服务（扇出 TodoItem / ExpenseRecord / StoredItem / IDDocumentItem / VoiceMemo）
@MainActor
public final class UnifiedSearchService: ObservableObject {
    public static let shared = UnifiedSearchService()

    @Published public var searchText: String = ""
    @Published public var results: [UnifiedSearchResultItem] = []
    @Published public var isSearching: Bool = false

    private init() {}

    /// 执行跨模块全量检索，受 AppLockManager 锁定状态约束对敏感项脱敏
    public func search(query: String, context: ModelContext, isLocked: Bool = false) async -> [UnifiedSearchResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.results = []
            return []
        }

        isSearching = true
        defer { isSearching = false }

        var items: [UnifiedSearchResultItem] = []

        // 1. 待办事项 (TodoItem)
        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> {
                $0.title.localizedStandardContains(trimmed) ||
                ($0.detail != nil && $0.detail!.localizedStandardContains(trimmed)) ||
                ($0.location != nil && $0.location!.localizedStandardContains(trimmed)) ||
                ($0.station != nil && $0.station!.localizedStandardContains(trimmed)) ||
                ($0.pickupCode != nil && $0.pickupCode!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let todos = try? context.fetch(todoDescriptor) {
            for t in todos.prefix(20) {
                let sub: String? = {
                    if let code = t.pickupCode, !code.isEmpty {
                        let stationText = t.station ?? t.location ?? ""
                        return "取件码：\(code) · \(stationText)"
                    }
                    return t.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? t.detail : (t.station ?? t.location)
                }()
                items.append(
                    UnifiedSearchResultItem(
                        id: t.id,
                        category: .todo,
                        title: t.title,
                        subtitle: sub,
                        date: t.dueAt ?? t.createdAt,
                        isSensitive: false,
                        targetTab: .todos,
                        vaultDestination: nil
                    )
                )
            }
        }

        // 2. 记账记录 (ExpenseRecord)
        let expenseDescriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate<ExpenseRecord> {
                $0.title.localizedStandardContains(trimmed) ||
                $0.categoryRaw.localizedStandardContains(trimmed) ||
                $0.rawText.localizedStandardContains(trimmed)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        if let expenses = try? context.fetch(expenseDescriptor) {
            for e in expenses.prefix(20) {
                let sign = e.isIncome ? "+" : "-"
                let amountText = String(format: "%@%.2f 元", sign, e.amount)
                items.append(
                    UnifiedSearchResultItem(
                        id: e.id,
                        category: .expense,
                        title: e.title,
                        subtitle: "\(amountText) · \(e.categoryRaw)",
                        date: e.date,
                        isSensitive: false,
                        targetTab: .expenses,
                        vaultDestination: nil
                    )
                )
            }
        }

        // 3. 收纳物品 (StoredItem)
        let storageDescriptor = FetchDescriptor<StoredItem>(
            predicate: #Predicate<StoredItem> {
                $0.name.localizedStandardContains(trimmed) ||
                $0.location.localizedStandardContains(trimmed) ||
                $0.roomArea.localizedStandardContains(trimmed) ||
                ($0.notes != nil && $0.notes!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if let stored = try? context.fetch(storageDescriptor) {
            for s in stored.prefix(20) {
                let loc = "\(s.roomArea) · \(s.location)"
                items.append(
                    UnifiedSearchResultItem(
                        id: s.id,
                        category: .storage,
                        title: s.name,
                        subtitle: loc,
                        date: s.updatedAt,
                        isSensitive: false,
                        targetTab: .vault,
                        vaultDestination: "storage"
                    )
                )
            }
        }

        // 4. 证件卡包 (IDDocumentItem) - 敏感项受 AppLock 约束
        let docDescriptor = FetchDescriptor<IDDocumentItem>(
            predicate: #Predicate<IDDocumentItem> {
                $0.title.localizedStandardContains(trimmed) ||
                $0.typeRaw.localizedStandardContains(trimmed) ||
                ($0.holderName != nil && $0.holderName!.localizedStandardContains(trimmed)) ||
                ($0.documentNumber != nil && $0.documentNumber!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if let docs = try? context.fetch(docDescriptor) {
            for d in docs.prefix(15) {
                let subtitleText: String? = {
                    if isLocked {
                        return "🔒 证件信息已加密锁定，解锁后查看"
                    }
                    if let num = d.documentNumber, !num.isEmpty {
                        return "\(d.type.displayName) · 号码：\(num)"
                    }
                    return d.type.displayName
                }()

                items.append(
                    UnifiedSearchResultItem(
                        id: d.id,
                        category: .document,
                        title: isLocked ? "🔒 \(d.type.displayName)" : d.title,
                        subtitle: subtitleText,
                        date: d.expiryDate ?? d.updatedAt,
                        isSensitive: true,
                        targetTab: .documents,
                        vaultDestination: "documents"
                    )
                )
            }
        }

        // 5. 语音备忘 (VoiceMemo)
        let memoDescriptor = FetchDescriptor<VoiceMemo>(
            predicate: #Predicate<VoiceMemo> {
                $0.title.localizedStandardContains(trimmed) ||
                ($0.transcription != nil && $0.transcription!.localizedStandardContains(trimmed)) ||
                ($0.summary != nil && $0.summary!.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let memos = try? context.fetch(memoDescriptor) {
            for m in memos.prefix(15) {
                let snippet = (m.summary ?? m.transcription ?? "").prefix(40)
                let sub = snippet.isEmpty ? "\(Int(m.duration)) 秒录音" : String(snippet)
                items.append(
                    UnifiedSearchResultItem(
                        id: m.id,
                        category: .memo,
                        title: m.title,
                        subtitle: sub,
                        date: m.createdAt,
                        isSensitive: false,
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
