import Foundation

extension CapabilityDescriptor {
    static let foodRecord = CapabilityDescriptor(
        id: "food.record",
        ownerModuleID: "food",
        displayName: "记录饮食",
        systemImage: "fork.knife",
        params: [
            .init("foodName", .text),
            .init("mealSlot", .enumeration(["早餐", "午餐", "晚餐", "加餐"]), required: false),
            .init("calories", .number, required: false),
            // 拍照识别 / 小票管线注入
            .init("dateISO", .dateTime, .nonModel, required: false),
            .init("foodID", .text, .nonModel, required: false),
            .init("rawText", .text, .nonModel, required: false),
            .init("imageDataBase64", .text, .nonModel, required: false)
        ],
        undoKinds: [.foodRecord],
        grammar: GrammarFragment(
            ruleName: "cap-food-record",
            ruleBody: #""{" ws "\"capability\":\"food.record\"" "," ws "\"foodName\":\"" text "\"" ("," ws "\"mealSlot\":\"" cap-food-meal-slot "\"")? ("," ws "\"calories\":\"" number "\"")? "}""#,
            terminals: [
                .init(name: "cap-food-meal-slot", body: #""早餐" | "午餐" | "晚餐" | "加餐""#)
            ]
        ),
        promptExample: #"饮食记录：{"capability":"food.record","foodName":"食物名","mealSlot":"早餐|午餐|晚餐|加餐","calories":"预估千卡可省"}"#,
        intentToken: "9",
        intentLegendName: "记录饮食"
    )
}
