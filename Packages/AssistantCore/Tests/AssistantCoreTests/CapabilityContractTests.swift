import XCTest
@testable import AssistantCore

/// 能力描述符与旧硬编码实现之间的等价性契约。
///
/// 迁移期间最容易出的事故是「描述符看着对，合成出来的文法少了一条产生式」，
/// 所以这里不比对描述符字段，而是把合成结果按旧规则名反向重命名后逐字对比。
final class CapabilityContractTests: XCTestCase {

    // MARK: - 文法等价

    func testComposedGrammarMatchesLegacyLanguage() throws {
        let legacy = parseRules(ActionJSONGrammar.gbnf)
        let composed = try CapabilityRegistry.grammar(enabledIDs: nil)
        let newRules = parseRules(composed.text)

        var rename: [String: String] = ["action": "action", "root": "root"]
        for descriptor in CapabilityRegistry.builtIn {
            let legacyName = descriptor.id.replacingOccurrences(of: ".", with: "-")
            guard let newName = composed.capabilityRuleNames[descriptor.id] else {
                return XCTFail("合成结果缺少能力规则：\(descriptor.id)")
            }
            rename[legacyName] = newName
            for terminal in descriptor.grammar?.terminals ?? [] {
                guard let legacyTerminal = legacy.first(where: { $0.body == terminal.body && $0.name != terminal.name }) else {
                    return XCTFail("找不到与 \(terminal.name) 同体的旧终结符")
                }
                rename[legacyTerminal.name] = terminal.name
            }
        }

        XCTAssertEqual(
            Set(legacy.map(\.name)).map { rename[$0] ?? $0 }.sorted(),
            Set(newRules.map(\.name)).sorted(),
            "规则集合必须一一对应"
        )

        for rule in legacy {
            let expectedName = rename[rule.name] ?? rule.name
            guard let actual = newRules.first(where: { $0.name == expectedName }) else {
                return XCTFail("合成文法缺少规则：\(expectedName)（旧名 \(rule.name)）")
            }
            XCTAssertEqual(
                renameIdentifiers(in: rule.body, using: rename),
                actual.body,
                "规则 \(rule.name) → \(expectedName) 的产生式变了"
            )
        }

        let legacyActionBody = legacy.first { $0.name == "action" }!.body
        XCTAssertEqual(
            composed.actionLine,
            "action ::= " + renameIdentifiers(in: legacyActionBody, using: rename)
        )
    }

    func testComposedRootAndKernelTerminalsAreUnchanged() throws {
        let legacy = Dictionary(uniqueKeysWithValues: parseRules(ActionJSONGrammar.gbnf).map { ($0.name, $0.body) })
        let composed = try CapabilityRegistry.grammar(enabledIDs: nil).text
        XCTAssertTrue(composed.hasPrefix(ActionGrammarComposer.rootRule))

        for terminal in ActionGrammarComposer.kernelTerminals {
            XCTAssertEqual(legacy[terminal.name], terminal.body, "内核终结符 \(terminal.name) 被改动")
        }
    }

    func testDisablingCapabilityRemovesItFromGrammar() throws {
        let composed = try CapabilityRegistry.grammar(enabledIDs: ["expense.create", "todo.complete"])
        XCTAssertEqual(Set(composed.capabilityRuleNames.keys), ["expense.create", "todo.complete"])
        XCTAssertEqual(composed.actionLine, "action ::= cap-expense-create | cap-todo-complete")
        XCTAssertFalse(composed.text.contains("cap-storage-record"))
        XCTAssertFalse(composed.text.contains("cap-water-beverage-type"), "未启用能力的私有终结符不应泄漏")
    }

    func testEmptyEnabledSetThrows() {
        XCTAssertThrowsError(try CapabilityRegistry.grammar(enabledIDs: [])) { error in
            XCTAssertEqual(error as? GrammarError, .emptyActionSpace)
        }
    }

    // MARK: - 提示词示例

    func testPromptExamplesMatchLegacySchema() {
        let golden: [String: String] = [
            "expense.create": #"记账：{"capability":"expense.create","amount":"数字","isIncome":"false","category":"餐饮美食|交通出行|居家日用|购物消费|休闲娱乐|医疗健康|宠物萌宠|数码家电|人情社交|职业收入|其它收入|其它支出","title":"简短事项名","dateISO":"yyyy-MM-dd HH:mm 可省"}"#,
            "expense.update": #"修改账目：{"capability":"expense.update","target":"原账单事项名或关键词","newAmount":"修改后金额"}"#,
            "todo.create": #"待办新建：{"capability":"todo.create","title":"待办标题","detail":"补充说明，可省","dueAtDays":"相对今天的天数，可省","dueAtTime":"HH:mm，可省"}"#,
            "todo.update": #"修改待办：{"capability":"todo.update","target":"原待办匹配关键词","newTitle":"新标题（可省）","dueAtDays":"新截止相对天数（可省）"}"#,
            "todo.complete": #"完成待办：{"capability":"todo.complete","target":"待完成事项匹配词"}"#,
            "todo.cancel": #"取消待办：{"capability":"todo.cancel","target":"待取消事项匹配词"}"#,
            "reminder.snooze": #"推迟提醒：{"capability":"reminder.snooze","target":"提醒事项匹配词","duration":"10分钟|1小时|明早"}"#,
            "query.lookup": #"查询事项：{"capability":"query.lookup","target":"查询关键词或完整问句（如「护照放哪了」「上周花了多少」「今天有什么安排」）"}"#,
            "memo.inbox": #"收集箱：{"capability":"memo.inbox","memo":"原文摘录"}"#,
            "food.record": #"饮食记录：{"capability":"food.record","foodName":"食物名","mealSlot":"早餐|午餐|晚餐|加餐","calories":"预估千卡可省"}"#,
            "water.record": #"饮水记录：{"capability":"water.record","beverageType":"白开水|纯茶|黑咖啡|拿铁|牛奶|奶茶|含糖饮料|苏打水","volumeML":"毫升数字","customName":"饮品名可省"}"#,
            "storage.record": #"物品收纳与常备药：{"capability":"storage.record","name":"物品或药品名","location":"详细存放位置","roomArea":"主卧|次卧|客厅|书房|玄关|厨房|阳台|储物间","isMedicine":"true|false"}"#,
            "habit.log": #"习惯与服药打卡：{"capability":"habit.log","target":"习惯名或药品名","kind":"habit|medication","dosage":"剂量可省"}"#,
            "anniversary.create": #"纪念日与到期预警：{"capability":"anniversary.create","title":"名称","category":"纪念日|生日|倒数日|订阅续费|保质期","targetDate":"yyyy-MM-dd可省","price":"金额可省"}"#,
            "departure.add": #"出门检查清单：{"capability":"departure.add","title":"随身物品名","scene":"工作通勤|运动健身|出差旅行|带娃出行|遛狗随行|雨雪出行|日常轻装","location":"放置位置可省"}"#,
            "life.record": #"家庭生活档案：{"capability":"life.record","domain":"pet|vehicle|child|skill|document|event","title":"事项或对象名","detail":"详情说明可省","value":"数值可省"}"#
        ]
        XCTAssertEqual(golden.count, CapabilityRegistry.builtIn.count)
        for descriptor in CapabilityRegistry.builtIn {
            XCTAssertEqual(descriptor.promptExample, golden[descriptor.id], "提示词示例漂移：\(descriptor.id)")
        }
    }

    // MARK: - 参数来源边界

    func testNonModelParamsNeverEnterGrammar() {
        for descriptor in CapabilityRegistry.builtIn {
            guard let grammar = descriptor.grammar else { continue }
            let text = ([grammar.ruleBody] + grammar.terminals.map(\.body)).joined(separator: "\n")
            for param in descriptor.params where param.origin == .nonModel {
                XCTAssertFalse(
                    text.contains("\\\"\(param.key)\\\":"),
                    "\(descriptor.id) 的非模型参数 \(param.key) 泄漏进了文法"
                )
            }
        }
    }

    func testEveryModelParamAppearsInGrammar() {
        for descriptor in CapabilityRegistry.builtIn {
            guard let grammar = descriptor.grammar else {
                return XCTFail("\(descriptor.id) 可被模型产出但缺少文法片段")
            }
            for param in descriptor.modelParams {
                XCTAssertTrue(
                    grammar.ruleBody.contains("\\\"\(param.key)\\\":"),
                    "\(descriptor.id) 的模型参数 \(param.key) 没有出现在文法里"
                )
            }
        }
    }

    // MARK: - 撤销归属

    func testUndoOwnershipIsCompleteAndUnique() {
        XCTAssertEqual(ActionUndoToken.Kind.allCases.count, 19)
        XCTAssertEqual(Set(CapabilityRegistry.undoHandlers.keys), Set(ActionUndoToken.Kind.allCases))

        var covered = Set<ActionUndoToken.Kind>()
        for descriptor in CapabilityRegistry.builtIn {
            for kind in descriptor.undoKinds {
                covered.insert(kind)
                let isRegisteredCrossModule = CapabilityRegistry.crossModuleUndoKinds[descriptor.id]?.contains(kind) == true
                XCTAssertTrue(
                    CapabilityRegistry.undoHandlers[kind] == descriptor.ownerModuleID || isRegisteredCrossModule,
                    "\(descriptor.id) 的撤销类型 \(kind.rawValue) 归属不一致且未登记为跨模块贡献"
                )
            }
        }
        XCTAssertEqual(covered, Set(ActionUndoToken.Kind.allCases))

        // 跨模块贡献必须显式登记，防止归属错配被注释掉后悄悄放过
        XCTAssertEqual(CapabilityRegistry.crossModuleUndoKinds, ["memo.inbox": [.foodRecord]])
    }

    // MARK: - 注册表自检

    func testRegistryCoversEveryCapabilityAndValidatesCleanly() throws {
        XCTAssertEqual(CapabilityRegistry.builtIn.count, 16)
        for capability in ActionCapability.allCases {
            XCTAssertNotNil(CapabilityRegistry.descriptor(for: capability), "缺少描述符：\(capability.rawValue)")
        }
        XCTAssertEqual(CapabilityRegistry.validate(), [])
        XCTAssertEqual(CapabilityRegistry.grammarText, try CapabilityRegistry.grammar(enabledIDs: nil).text)
    }

    // MARK: - GBNF 解析辅助

    private func parseRules(_ text: String) -> [(name: String, body: String)] {
        text.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let range = line.range(of: " ::= ") else { return nil }
            return (
                String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// 只重命名引号外的标识符；引号内的字面量（中文枚举、JSON 字段名）保持不变。
    private func renameIdentifiers(in body: String, using map: [String: String]) -> String {
        var result = ""
        var identifier = ""
        var inQuote = false
        var escaped = false

        func flush() {
            guard !identifier.isEmpty else { return }
            result += map[identifier] ?? identifier
            identifier = ""
        }

        for character in body {
            if inQuote {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuote = false
                }
                continue
            }
            if character == "\"" {
                flush()
                inQuote = true
                result.append(character)
            } else if character.isLetter || character.isNumber || character == "-" || character == "_" {
                identifier.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }
}
