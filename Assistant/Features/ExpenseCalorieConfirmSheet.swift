import AssistantCore
import SwiftData
import SwiftUI

/// 记账后弹出的热量确认：显示估算、允许改数字，用户点「记录」才写入饮食记录。
struct ExpenseCalorieConfirmSheet: View {
    @Environment(\.modelContext) private var context
    let pending: PendingCalorieSuggestion

    @State private var caloriesText: String

    init(pending: PendingCalorieSuggestion) {
        self.pending = pending
        _caloriesText = State(initialValue: String(Int(pending.suggestion.fullPortionCalories.rounded())))
    }

    private var parsedCalories: Double? {
        guard let v = Double(caloriesText.trimmingCharacters(in: .whitespaces)),
              ExpenseFoodMatcher.plausibleCalorieRange.contains(v) || v == 0 else { return nil }
        return v > 0 ? v : nil
    }

    private var slot: MealSlot {
        ExpenseFoodMatcher.mealSlot(for: pending.date, foodID: pending.suggestion.foodID)
    }

    private var originNote: String {
        switch pending.suggestion.origin {
        case .catalog: return "按内置食物库估算，份量与做法会带来误差。"
        case .llm: return "食物库里没有这一项，由本地模型推测，误差可能较大，请核对后再记录。"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("账单", value: pending.title)
                    LabeledContent("识别为", value: "\(pending.suggestion.name)（\(pending.suggestion.portion.displayName)）")
                    LabeledContent("归入", value: slot.displayName)
                }
                Section {
                    HStack {
                        Text("热量")
                        Spacer()
                        TextField("千卡", text: $caloriesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("千卡").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(originNote)
                }
                if pending.existingRecordID != nil {
                    Section {
                        Text("这笔账单已改动，原来的热量记录会被更新；选「不记录」将移除原记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("记录这笔的热量？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("不记录") {
                        ExpenseCalorieService.decline(pending, context: context)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记录") {
                        if let kcal = parsedCalories {
                            ExpenseCalorieService.confirm(pending, calories: kcal, context: context)
                        }
                    }
                    .disabled(parsedCalories == nil)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

private struct ExpenseCalorieConfirmationModifier: ViewModifier {
    @ObservedObject private var center = ExpenseCalorieCenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $center.pending) { pending in
            ExpenseCalorieConfirmSheet(pending: pending)
        }
    }
}

extension View {
    /// 挂载「记账 → 热量」确认弹窗。
    func expenseCalorieConfirmation() -> some View {
        modifier(ExpenseCalorieConfirmationModifier())
    }
}
