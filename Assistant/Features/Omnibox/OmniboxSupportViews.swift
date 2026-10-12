import SwiftData
import SwiftUI

// MARK: - 收集箱列表（memo.inbox 落地的备忘内容）

struct OmniboxMemoListView: View {
    struct MemoLine: Identifiable {
        let id = UUID()
        let dateText: String?
        let text: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var memos: [MemoLine] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if memos.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("收集箱是空的"),
                        systemImage: "tray",
                        description: Text(L10n.tr("投喂口无法归类的随手内容都会先落在这里"))
                    )
                } else {
                    List {
                        ForEach(memos) { memo in
                            VStack(alignment: .leading, spacing: 3) {
                                if let dateText = memo.dateText {
                                    Text(dateText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(memo.text)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { offsets in
                            memos.remove(atOffsets: offsets)
                            persist()
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("收集箱"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.tr("关闭")) { dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    /// 文件行格式："[yyyy-MM-dd HH:mm] 内容"（与 OmniboxExecutor 写入格式一致）
    private func load() {
        guard let raw = try? String(contentsOf: OmniboxExecutor.memoFileURL, encoding: .utf8) else { return }
        let lines = raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> MemoLine in
                if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                    let dateText = String(line[line.index(after: line.startIndex)..<end])
                    let text = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                    return MemoLine(dateText: dateText, text: text)
                }
                return MemoLine(dateText: nil, text: line)
            }
        // 文件按写入顺序（旧→新），展示新→旧
        memos = lines.reversed()
    }

    private func persist() {
        // 展示顺序是新→旧，写回时翻转恢复文件顺序
        let lines = memos.reversed().map { memo -> String in
            memo.dateText.map { "[\($0)] \(memo.text)" } ?? memo.text
        }
        try? lines.joined(separator: "\n").write(
            to: OmniboxExecutor.memoFileURL,
            atomically: true,
            encoding: .utf8
        )
    }
}

// MARK: - 历史投喂（事务列表 + 跨启动撤销）

struct OmniboxHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \OmniboxTransaction.createdAt, order: .reverse)
    private var transactions: [OmniboxTransaction]
    @State private var undoError: String?
    @State private var showUndoError = false

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("还没有投喂记录"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(L10n.tr("每次投喂都会在这里留一条可追溯的事务"))
                    )
                } else {
                    List {
                        ForEach(transactions) { transaction in
                            transactionRow(transaction)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                context.delete(transactions[index])
                            }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("投喂历史"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.tr("关闭")) { dismiss() }
                }
            }
            .alert(L10n.tr("撤销失败"), isPresented: $showUndoError) {
                Button(L10n.tr("好"), role: .cancel) {}
            } message: {
                Text(undoError ?? "")
            }
        }
    }

    private func transactionRow(_ transaction: OmniboxTransaction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusTag(transaction.status)
                Spacer()
                Text(transaction.engineRaw == "llm" ? "AI" : L10n.tr("规则"))
                    .font(.caption2.bold())
                    .foregroundStyle(.purple)
                if transaction.imageCount > 0 {
                    Label("\(transaction.imageCount)", systemImage: "photo.on.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(transaction.decodedActions) { action in
                Label(
                    action.summary.isEmpty ? action.capability.displayName : action.summary,
                    systemImage: action.capability.systemImage
                )
                .font(.caption)
                .lineLimit(1)
            }

            if transaction.status == .executed, let tokens = decodedUndoTokens(transaction), !tokens.isEmpty {
                Button(role: .destructive) {
                    undo(transaction, tokens: tokens)
                } label: {
                    Label(L10n.tr("撤销此次投喂"), systemImage: "arrow.uturn.backward")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusTag(_ status: OmniboxTransactionStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .planned: return (L10n.tr("未执行"), .gray)
            case .executed: return (L10n.tr("已执行"), .green)
            case .undone: return (L10n.tr("已撤销"), .orange)
            }
        }()
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func decodedUndoTokens(_ transaction: OmniboxTransaction) -> [OmniboxUndoToken]? {
        guard let undoJSON = transaction.undoJSON else { return nil }
        return try? JSONDecoder().decode([OmniboxUndoToken].self, from: undoJSON)
    }

    private func undo(_ transaction: OmniboxTransaction, tokens: [OmniboxUndoToken]) {
        do {
            try OmniboxExecutor.undoTokens(tokens, context: context)
            transaction.status = .undone
            transaction.undoJSON = nil
            try? context.save()
            WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        } catch {
            undoError = error.localizedDescription
            showUndoError = true
        }
    }
}
