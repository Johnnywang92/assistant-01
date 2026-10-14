import XCTest
@testable import AssistantCore

/// GBNF 文法只做结构完整性校验（真正解析由 llama.cpp 在真机推理时完成）
final class ActionGrammarTests: XCTestCase {

    func testGrammarCoversAllCapabilities() {
        for capability in ActionCapability.allCases {
            // GBNF 里引号以 \" 转义写出，这里对照的是文法原文中的字面量
            XCTAssertTrue(
                ActionJSONGrammar.gbnf.contains("\\\"capability\\\":\\\"\(capability.rawValue)\\\""),
                "文法必须覆盖 capability：\(capability.rawValue)"
            )
        }
        XCTAssertEqual(ActionCapability.allCases.count, 9)
    }

    func testGrammarRootRuleAndReferenceNameMatch() {
        XCTAssertEqual(ActionJSONGrammar.rootName, "root")
        XCTAssertTrue(ActionJSONGrammar.gbnf.hasPrefix("root ::="))
        // 根规则强制「至少一个动作对象」：模型无法输出空数组来静默躲开拆解
        XCTAssertTrue(ActionJSONGrammar.gbnf.contains(#""[" ws action ("," ws action)* ws "]""#))
    }

    func testGrammarAllowsFreeChineseTargetText() {
        // target 是自由中文串：char 规则需允许任意非引号/反斜杠字符（含中文），并支持 JSON 转义
        XCTAssertTrue(ActionJSONGrammar.gbnf.contains(#"char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)"#))
    }

    func testGrammarEnumFieldsMatchInstructionSchema() {
        // 分类与时长枚举需与提示词 schema 一致，否则合法输出会被文法拒掉
        XCTAssertTrue(ActionJSONGrammar.gbnf.contains(#"duration ::= "10分钟" | "1小时" | "明早""#))
        for category in ["餐饮美食", "交通出行", "居家日用", "购物消费", "休闲娱乐", "医疗健康",
                         "宠物萌宠", "数码家电", "人情社交", "职业收入", "其它收入", "其它支出"] {
            XCTAssertTrue(ActionJSONGrammar.gbnf.contains("\"\(category)\""), "缺少分类：\(category)")
        }
    }

    func testGrammarRuleNamesAreDefined() {
        // 每个引用到的自定义规则都必须有 ::= 定义，防改名后文法解析失败
        let defined = ActionJSONGrammar.gbnf
            .split(separator: "\n")
            .compactMap { $0.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } }
        let expectedRules = [
            "root", "ws", "action", "expense-create", "expense-update", "todo-create", "todo-update",
            "todo-complete", "todo-cancel", "reminder-snooze", "query-lookup", "memo-inbox",
            "number", "days", "time", "date", "datetime", "is-income", "duration", "category",
            "text", "char", "hex"
        ]
        for rule in expectedRules {
            XCTAssertTrue(defined.contains(rule), "规则 \(rule) 缺少定义")
        }
    }

    func testGrammarOutputIsAcceptedByParserContract() {
        // 用文法约束下的典型输出反喂宽容解析器：文法产出必须能直接解析
        let sample = #"[{"capability":"expense.create","amount":"15.5","isIncome":"false","category":"餐饮美食","title":"午餐"},{"capability":"todo.complete","target":"取快递"}]"#
        guard case .ok(let actions) = ActionOutputParser.classify(sample) else {
            return XCTFail("文法典型输出必须可解析")
        }
        XCTAssertEqual(actions.map(\.capability), [.expenseCreate, .todoComplete])
    }
}
