import AssistantCore
import Foundation
import UIKit

// MARK: - Omnibox Planner：Capture → PlannedAction[]

/// 理解层。两种引擎：
/// 1. LLM 路径：一次多模态归一（图片先 OCR）后让端侧模型直接产出 schema 化 JSON 动作数组
/// 2. 规则兜底：正则/关键词拆解（LLM 不可用或输出解析失败时）
/// Planner 不执行动作，只负责产出 DAG 并保证拓扑可执行。
struct OmniboxPlanner {

    struct PlanResult {
        var actions: [PlannedAction]
        var engine: String // "llm" / "rules"
        var normalizedText: String
        /// LLM 路径未采纳的原因（解析失败/空数组/模型不可用）；nil 表示未降级或 LLM 成功。
        /// 「无静默丢动作」验收凭据：engine == "rules" 且 LLM 曾被尝试时此字段必非空并进日志。
        var fallbackReason: String? = nil
        /// 判别层输出的意图分布（若判别成功）。UI 用它解释「为什么判成这一类」，
        /// 也用于把真实置信度透传给确认卡，而不是靠硬编码常量。
        var intentDistribution: IntentDistribution? = nil
        /// 判别成功但置信不足：应提示用户补充，而非硬猜。
        var needsClarification: Bool = false
        /// 用户点选的强制意图（按可能性排序预填写的选中项）；nil 表示未指定。
        var forcedCapability: ActionCapability? = nil
    }

    struct DetectedFoodInfo {
        var estimate: FoodCalorieEstimate
        var thumbnailData: Data?
    }

    /// - Parameters:
    ///   - forcedCapability: 用户从「可能性排序」候选里点选的意图。
    ///     指定后拆解只围绕该意图展开（LLM 提示词收窄到单一能力，规则路径优先产出该能力），
    ///     即「按可能性排序拆解 → 预填写」的切换入口。
    ///   - feedback: 点赞/点踩回流记忆。被点踩过的输入强制进确认；被点赞过的意图优先预填。
    func plan(
        capture: OmniboxCapture,
        forcedCapability: ActionCapability? = nil,
        feedback: IntentFeedbackMemory = IntentFeedbackMemory()
    ) async -> PlanResult {
        // 1. 归一输入：文字直接收集；图片并发 OCR（多图时比串行快数倍），并进行端侧食物视觉识别
        var parts: [String] = []
        var imageDatas: [Data] = []
        var userTextParts: [String] = []
        for payload in capture.payloads {
            switch payload {
            case .text(let t), .audioTranscript(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                    userTextParts.append(trimmed)
                }
            case .image(let data):
                imageDatas.append(data)
            }
        }
        let userRawText = userTextParts.joined(separator: " ")
        let imageCount = imageDatas.count

        var detectedFoodInfos: [DetectedFoodInfo] = []
        /// 图片结构化识别（票务/小票）直接产出的动作，不再让文本流重猜
        var structuredActions: [PlannedAction] = []
        /// 已被票务/小票认领的图片下标：不再喂给食物视觉，避免把票根识别成「餐食」
        var claimedImageIndices = Set<Int>()

        if !imageDatas.isEmpty {
            // 并发结构化识别（内含全文 OCR + 二维码/票务提取），按提交顺序回填保持图文对应
            let recognitions: [(Int, ImageTodoRecognitionResult?)] = await withTaskGroup(
                of: (Int, ImageTodoRecognitionResult?).self,
                returning: [(Int, ImageTodoRecognitionResult?)].self
            ) { group in
                for (index, data) in imageDatas.enumerated() {
                    group.addTask {
                        guard let image = UIImage(data: data) else { return (index, nil) }
                        return (index, try? await OCRService.shared.recognizeTodo(from: image))
                    }
                }
                var results = [ImageTodoRecognitionResult?](repeating: nil, count: imageDatas.count)
                for await (index, recognition) in group {
                    results[index] = recognition
                }
                return results.enumerated().map { ($0.offset, $0.element) }
            }

            for (index, recognition) in recognitions {
                guard let recognition else { continue }

                // 1. 票务/预约/行程等结构化命中 → 直接产出待办动作（带类型/时间/取票码/站点）
                if forcedCapability == nil || forcedCapability == .todoCreate,
                   let todo = Self.structuredTodoAction(from: recognition) {
                    structuredActions.append(todo)
                    claimedImageIndices.insert(index)
                    continue
                }

                // 2. 小票/发票（存在明确「合计/实付」总额标签）→ 直接产出记账动作
                if forcedCapability == nil || forcedCapability == .expenseCreate,
                   let expense = Self.structuredExpenseAction(from: recognition.rawText) {
                    structuredActions.append(expense)
                    claimedImageIndices.insert(index)
                    continue
                }

                // 3. 兜底：未命中结构化的图片文本回流文本管线（LLM/规则拆解）
                let trimmed = recognition.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append("【图片识别内容】\n\(trimmed)")
                }
            }

            // 对未被结构化认领的图片进行端侧食物与饮食热量视觉识别（支持托盘餐、单品菜肴、饮品等）
            for (index, data) in imageDatas.enumerated() where !claimedImageIndices.contains(index) {
                guard let image = UIImage(data: data) else { continue }
                if let foodInfo = await Self.detectFoodInImage(image, userText: userRawText) {
                    detectedFoodInfos.append(foodInfo)
                    parts.append("【食物与热量识别】\n\(foodInfo.estimate.displayName) · 预估 \(Int(foodInfo.estimate.fullPortionCalories))千卡")
                }
            }
        }
        let normalizedText = parts.joined(separator: "\n\n")

        guard !normalizedText.isEmpty || imageCount > 0 else {
            return PlanResult(actions: [], engine: "rules", normalizedText: "")
        }

        // 1.5 大模型决策输出分流（缺口 6）：长文带「行动待办」结构的粘贴内容不再走
        //     16 类意图判别（会被误判成收集箱备忘），直接复用人生大事的导入解析器拆行动项。
        //     用户显式点选意图时不劫持——尊重用户指定。分流在判别层之前，分布为 nil。
        if forcedCapability == nil,
           LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(normalizedText) {
            let decisionActions = Self.aiDecisionActions(from: normalizedText)
            let merged = IntentConfidenceCalibrator.applySelectionPolicy(structuredActions + decisionActions)
            return PlanResult(
                actions: merged,
                engine: "rules",
                normalizedText: normalizedText,
                intentDistribution: nil,
                needsClarification: false,
                forcedCapability: forcedCapability
            )
        }

        let foodThumbnailBase64 = detectedFoodInfos.first?.thumbnailData?.base64EncodedString()

        // 反馈回流：被点踩过的输入不再默认信模型（强制进确认）；
        // 被点赞过的意图优先预填（提升到判别分布首位）。
        let disputedInput = !normalizedText.isEmpty && feedback.isDisputed(normalizedText)

        // 2. 意图判别：先分类再抽取。判别层只决定「是哪一类」，参数仍由 LLM 抽。
        //    这一步的收益是把 16 类判别与参数抽取解耦——抽取阶段的提示词只需讲 1 类，
        //    且我们第一次拿到了**真实概率**（生成式路径的 confidence 是写死的常量）。
        var distribution: IntentDistribution?
        if !normalizedText.isEmpty, forcedCapability == nil {
            do {
                let routed = try await OmniboxIntentRouter().route(normalizedText)
                distribution = feedback.promoted(routed.distribution, for: normalizedText)
            } catch {
                // 判别失败（模型未就绪 / logits 不可读 / 标签映射不成立）不是致命错误，
                // 直接降级到原有的生成式路径，保持既有行为不退化。
                print("⚠️ [Omnibox] 意图判别不可用，回退生成式路径：\(error.localizedDescription)")
            }
        }

        // 3. LLM 优先：解析失败先带一次纠正重试，仍失败才降级规则兜底，且降级原因必须留痕
        //    图片结构化动作（票务/小票）排最前——它们来自确定性识别，不是模型猜测。
        if !normalizedText.isEmpty {
            let outcome = await Self.llmPlan(normalizedText, intentHint: distribution, forcedCapability: forcedCapability)
            if let actions = outcome.actions, !actions.isEmpty {
                let enriched = Self.enrichForeignCurrencyIfNeeded(actions: actions, sourceText: normalizedText)
                let sanitized = Self.sanitizeAndEnrichLLMActions(actions: enriched, sourceText: normalizedText)
                let calibrated = IntentConfidenceCalibrator.apply(to: sanitized, distribution: distribution)
                let withImages = Self.attachImageDataIfNeeded(actions: calibrated, foodThumbnailBase64: foodThumbnailBase64)
                let merged = IntentConfidenceCalibrator.applySelectionPolicy(structuredActions + withImages)
                return PlanResult(
                    actions: merged,
                    engine: "llm",
                    normalizedText: normalizedText,
                    intentDistribution: distribution,
                    needsClarification: disputedInput || IntentConfidenceCalibrator.needsClarification(merged),
                    forcedCapability: forcedCapability
                )
            }
            let reason = outcome.fallbackReason ?? "未知原因"
            print("⚠️ [Omnibox] LLM 路径未采纳，已降级规则引擎：\(reason)｜归一文 \(normalizedText.count) 字")
            var ruleActions = Self.attachImageDataIfNeeded(
                actions: Self.rulePlan(normalizedText, preferredCapability: forcedCapability),
                foodThumbnailBase64: foodThumbnailBase64
            )
            ruleActions = IntentConfidenceCalibrator.applySelectionPolicy(structuredActions + ruleActions)
            return PlanResult(
                actions: ruleActions,
                engine: "rules",
                normalizedText: normalizedText,
                fallbackReason: reason,
                intentDistribution: distribution,
                // 规则引擎自己带置信度（短信模板 0.9、松散金额 0.55），
                // 不该被模型判别层的低置信覆盖——模板命中本来就是确定信号。
                needsClarification: disputedInput || IntentConfidenceCalibrator.needsClarification(ruleActions),
                forcedCapability: forcedCapability
            )
        }
        // 纯图片且文本流无内容：结构化命中时照常返回动作，否则留痕空动作
        let fallbackActions = IntentConfidenceCalibrator.applySelectionPolicy(
            structuredActions + Self.attachImageDataIfNeeded(actions: [], foodThumbnailBase64: foodThumbnailBase64)
        )
        return PlanResult(
            actions: fallbackActions,
            engine: "rules",
            normalizedText: normalizedText,
            needsClarification: disputedInput,
            forcedCapability: forcedCapability
        )
    }

    // MARK: - 图片结构化识别 → 动作（票务/小票）

    /// 票务/预约/行程等结构化识别结果 → 待办动作。
    ///
    /// 只认「识别器给了明确结构」的结果（标题非兜底、且带时间/取票码/行程元数据），
    /// 低置信或纯文本命中交回文本管线，不硬编。
    private static func structuredTodoAction(from recognition: ImageTodoRecognitionResult) -> PlannedAction? {
        // 兜底标题说明没提炼出事件名，置信度已被识别器压到 0.48 以下
        guard recognition.title != "图片识别待办事项",
              recognition.confidence >= 0.72,
              recognition.dueAt != nil
                || recognition.pickupCode != nil
                || recognition.travelPickup != nil
                || recognition.station != nil else { return nil }

        var params: [String: String] = [
            "title": recognition.title,
            "typeRaw": recognition.type.rawValue
        ]
        var detailParts: [String] = []
        if let detail = recognition.detail, !detail.isEmpty { detailParts.append(detail) }
        if let slot = recognition.timeSlotText, !slot.isEmpty { detailParts.append(slot) }
        if !detailParts.isEmpty { params["detail"] = detailParts.joined(separator: " · ") }
        if let dueAt = recognition.dueAt {
            params["dueAtISO"] = dateTimeFormatter.string(from: dueAt)
        }
        if let code = recognition.pickupCode, !code.isEmpty { params["pickupCode"] = code }
        if let station = recognition.station, !station.isEmpty { params["station"] = station }
        if let location = recognition.location, !location.isEmpty { params["location"] = location }
        if let qr = recognition.qrCodePayload, !qr.isEmpty { params["qrCodePayload"] = qr }
        if let pickup = recognition.travelPickup {
            params["arrivalAtISO"] = dateTimeFormatter.string(from: pickup.arrivalAt)
            params["arrivalTransport"] = pickup.isFlight ? "flight" : "train"
            params["travelPickupMode"] = pickup.isPickupMode ? "pickup" : "travel"
        }

        return PlannedAction(
            capability: .todoCreate,
            params: params,
            confidence: recognition.confidence,
            confidenceReason: recognition.confidenceReason ?? "图片票务结构化识别",
            summary: Self.summary(for: .todoCreate, params: params)
        )
    }

    /// 小票/发票 OCR 文本 → 记账动作。
    ///
    /// 只认「合计/实付」等明确总额标签（`hasLabeledTotal`）：普通文稿里的数字
    /// 绝不能被误建账。松散金额场景仍走文本管线，由 LLM/规则结合语境判断。
    private static func structuredExpenseAction(from rawText: String) -> PlannedAction? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ReceiptTextParser.hasLabeledTotal(trimmed) else { return nil }

        let parsed = ReceiptTextParser.parse(trimmed)
        guard parsed.amount > 0 else { return nil }

        var params: [String: String] = [
            "amount": String(format: "%.2f", parsed.amount),
            "isIncome": "false",
            "category": parsed.categoryRaw,
            "title": parsed.title
        ]
        params["dateISO"] = dateTimeFormatter.string(from: parsed.date)

        return PlannedAction(
            capability: .expenseCreate,
            params: params,
            confidence: parsed.confidence,
            confidenceReason: parsed.confidenceReason ?? "小票总额标签识别",
            summary: Self.summary(for: .expenseCreate, params: params)
        )
    }

    /// 若识别出食物照片，为所有食物记录动作挂载缩略图 Base64，落库时同步存储照片
    private static func attachImageDataIfNeeded(actions: [PlannedAction], foodThumbnailBase64: String?) -> [PlannedAction] {
        guard let foodThumbnailBase64 else { return actions }
        return actions.map { action in
            guard action.capability == .foodRecord else { return action }
            var updated = action
            if updated.params["imageDataBase64"] == nil {
                updated.params["imageDataBase64"] = foodThumbnailBase64
            }
            return updated
        }
    }

    // MARK: - LLM 路径

    /// 返回动作数组与降级原因：actions 为 nil/空时 fallbackReason 必非空（审计凭据）
    ///
    /// - Parameters:
    ///   - intentHint: 判别层给出的意图分布。为 nil 时行为与旧版完全一致
    ///     （列出全部 16 类让模型自己判）；非 nil 时按判别结果收窄候选能力，
    ///     让抽取阶段的提示词只讲最可能的 2~3 类，弱模型受益明显。
    ///   - forcedCapability: 用户从可能性排序里点选的意图，收窄到单一能力（预填写路径）。
    private static func llmPlan(
        _ text: String,
        intentHint: IntentDistribution? = nil,
        forcedCapability: ActionCapability? = nil
    ) async -> (actions: [PlannedAction]?, fallbackReason: String?) {
        let systemInstruction = Self.makeSystemInstruction(intentHint: intentHint, forcedCapability: forcedCapability)
        let now = Date()
        let dateText = Self.yyyyMMdd.string(from: now)
        let weekdayText = Self.weekdayFormatter.string(from: now)
        var baseUserContent = "今天是\(dateText) \(weekdayText)。\n输入：\n\(text)"
        if let forcedCapability {
            baseUserContent += "\n（用户明确选择意图：「\(forcedCapability.displayName)」，请只抽取该类动作）"
        } else if let hint = intentHint, hint.top != nil {
            baseUserContent += "\n（意图判别结果：\(hint.reasonText)，请据此抽取参数）"
        }

        // GBNF 约束下的生成理论上必是合法数组；分类+重试兜住文法未生效的场景
        // （局域网 Ollama 通道、grammar sampler 初始化失败降级）
        var attempt = 0
        var userContent = baseUserContent
        while true {
            guard let raw = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: systemInstruction,
                userContent: userContent,
                maxNewTokens: 400,
                grammarGBNF: ActionJSONGrammar.gbnf
            ), !raw.isEmpty else {
                return (nil, "端侧模型未返回可用输出（第 \(attempt + 1) 次尝试）")
            }

            let decision = ActionOutputParser.classify(raw)
            switch decision {
            case .ok(let actions):
                return (actions, nil)
            case .emptyArray:
                // 模型明确返回空数组：不是解析失败，不消耗重试算力，直接交规则兜底并留痕
                return (nil, "模型返回空动作数组")
            case .failed(let reason):
                guard ActionOutputParser.shouldRetry(decision: decision, attempt: attempt) else {
                    return (nil, attempt == 0
                        ? "解析失败：\(reason.rawValue)"
                        : "纠正重试 \(attempt) 次后仍失败：\(reason.rawValue)")
                }
                print("⚠️ [Omnibox] 模型输出解析失败（\(reason.rawValue)），纠正重试 \(attempt + 1)/\(ActionOutputParser.maxCorrectiveRetries)")
                userContent = ActionOutputParser.correctiveUserContent(original: baseUserContent, failedOutput: raw)
                attempt += 1
            }
        }
    }

    /// 宽容解析模型输出：剥掉 markdown 围栏、截取最外层 JSON 数组（委托 AssistantCore.ActionParser）
    static func parseActionJSON(_ raw: String) -> [PlannedAction]? {
        ActionParser.parseActionJSON(raw)
    }

    /// 抽取阶段的系统提示词。
    ///
    /// 有判别结论时只讲最可能的 2~3 类能力，让弱模型的注意力集中在少数选项上；
    /// 用户点选了意图（forcedCapability）时只讲那一类；判别不可用或分布过于分散
    /// （top1 概率低于 0.4，说明模型确实没分清）时，退回列出全部 16 类，
    /// 避免用错误的先验把模型锁死在错的那一类。
    private static func makeSystemInstruction(
        intentHint: IntentDistribution?,
        forcedCapability: ActionCapability? = nil
    ) -> String {
        let schema = Self.capabilitySchema

        if let forcedCapability {
            return Self.basePrompt(schema: schema, narrowed: [forcedCapability], hint: intentHint, forced: true)
        }

        guard let hint = intentHint, let top = hint.top, hint.topProbability >= 0.4 else {
            return Self.basePrompt(schema: schema)
        }

        // 次选保留，用于给模型一个纠错出口；概率都低于 0.15 的类别不列出，纯属噪声。
        let candidates = hint.ranked
            .filter { $0.label != top && $0.probability >= 0.15 }
            .prefix(1)
            .map(\.label)

        guard !candidates.isEmpty else {
            return Self.basePrompt(schema: schema, narrowed: [top.capability], hint: hint)
        }
        return Self.basePrompt(schema: schema, narrowed: [top.capability] + candidates.map(\.capability), hint: hint)
    }

    /// 16 类全域能力的字段模板。判别收窄时按 capability 过滤，
    /// 保证收窄后模型看到的模板与允许的动作严格一致（不一致会诱发幻觉字段）。
    private static var capabilitySchema: [(capability: ActionCapability, line: String)] {
        [
            (.expenseCreate, #"1) 记账：{"capability":"expense.create","amount":"数字","isIncome":"false","category":"餐饮美食|交通出行|居家日用|购物消费|休闲娱乐|医疗健康|宠物萌宠|数码家电|人情社交|职业收入|其它收入|其它支出","title":"简短事项名","dateISO":"yyyy-MM-dd HH:mm 可省"}"#),
            (.expenseUpdate, #"修改账目：{"capability":"expense.update","target":"原账单事项名或关键词","newAmount":"修改后金额"}"#),
            (.todoCreate, #"待办新建：{"capability":"todo.create","title":"待办标题","detail":"补充说明，可省","dueAtDays":"相对今天的天数，可省","dueAtTime":"HH:mm，可省"}"#),
            (.todoUpdate, #"修改待办：{"capability":"todo.update","target":"原待办匹配关键词","newTitle":"新标题（可省）","dueAtDays":"新截止相对天数（可省）"}"#),
            (.todoComplete, #"完成待办：{"capability":"todo.complete","target":"待完成事项匹配词"}"#),
            (.todoCancel, #"取消待办：{"capability":"todo.cancel","target":"待取消事项匹配词"}"#),
            (.reminderSnooze, #"推迟提醒：{"capability":"reminder.snooze","target":"提醒事项匹配词","duration":"10分钟|1小时|明早"}"#),
            (.queryLookup, #"查询事项：{"capability":"query.lookup","target":"查询关键词或完整问句（如「护照放哪了」「上周花了多少」「今天有什么安排」）"}"#),
            (.memoInbox, #"收集箱：{"capability":"memo.inbox","memo":"原文摘录"}"#),
            (.foodRecord, #"饮食记录：{"capability":"food.record","foodName":"食物名","mealSlot":"早餐|午餐|晚餐|加餐","calories":"预估千卡可省"}"#),
            (.waterRecord, #"饮水记录：{"capability":"water.record","beverageType":"白开水|纯茶|黑咖啡|拿铁|牛奶|奶茶|含糖饮料|苏打水","volumeML":"毫升数字","customName":"饮品名可省"}"#),
            (.storageRecord, #"物品收纳与常备药：{"capability":"storage.record","name":"物品或药品名","location":"详细存放位置","roomArea":"主卧|次卧|客厅|书房|玄关|厨房|阳台|储物间","isMedicine":"true|false"}"#),
            (.habitLog, #"习惯与服药打卡：{"capability":"habit.log","target":"习惯名或药品名","kind":"habit|medication","dosage":"剂量可省"}"#),
            (.anniversaryCreate, #"纪念日与到期预警：{"capability":"anniversary.create","title":"名称","category":"纪念日|生日|倒数日|订阅续费|保质期","targetDate":"yyyy-MM-dd可省","price":"金额可省"}"#),
            (.departureAdd, #"出门检查清单：{"capability":"departure.add","title":"随身物品名","scene":"工作通勤|运动健身|出差旅行|带娃出行|遛狗随行|雨雪出行|日常轻装","location":"放置位置可省"}"#),
            (.lifeRecord, #"家庭生活档案：{"capability":"life.record","domain":"pet|vehicle|child|skill|document|event","title":"事项或对象名","detail":"详情说明可省","value":"数值可省"}"#)
        ]
    }

    private static func basePrompt(
        schema: [(capability: ActionCapability, line: String)],
        narrowed: [ActionCapability]? = nil,
        hint: IntentDistribution? = nil,
        forced: Bool = false
    ) -> String {
        let lines: String
        if let narrowed {
            lines = schema.filter { narrowed.contains($0.capability) }
                .map(\.line)
                .joined(separator: "\n")
        } else {
            lines = schema.map { "\($0.line)" }.joined(separator: "\n")
        }

        var prompt = """
        你是个人助手的万能投喂口与智能助理理解引擎。把用户输入拆解为可执行动作，只输出一个 JSON 数组，不要输出任何解释、markdown 或多余文字。
        可用动作：
        \(lines)
        规则：
        """
        if forced {
            prompt += """
            - 用户已明确选择动作类型，必须输出该类型的动作；即使表述含糊，也按该类型预填参数。
            """
        } else if let hint, let top = hint.top {
            prompt += """
            - 意图判别倾向于「\(top.displayName)」，但仍需按输入实际内容核对；若明显不符，输出更合适的动作。
            """
        }
        prompt += """
        - 提到“完成”、“搞定”、“做好了”某个待办时，必须输出 todo.complete 动作，target 为事项名。
        - 提到“取消”、“删掉”、“不要提醒”某个事项时，输出 todo.cancel 动作。
        - 提到“推迟”、“稍后提醒”、“延后”时，输出 reminder.snooze 动作。
        - 识别到消费/支出金额且非修改时，输出 expense.create 动作。一句话含多笔消费时（如“咖啡10.9元，午餐22元，公交1元”），为每一笔分别输出一条 expense.create 动作，标题与金额不得合并。
        - 【纯饮食与饮水边界】：若用户仅描述吃了什么食物（如“早饭吃了一根玉米和一杯牛奶”）且未提及花费金额，绝不虚构金额输出 expense.create，必须输出 food.record！若仅描述喝水或喝咖啡/茶/奶茶/饮料（如“喝了500ml水”、“喝了一杯冰美式”），输出 water.record。
        - 【物品收纳与常备药】：提到“把X放在Y”、“X收在Y”、“药箱备了X”时，输出 storage.record 动作。
        - 【习惯与服药打卡】：提到“吃了XX药”、“服用了维生素”、“完成晨跑打卡”、“早起打卡”时，输出 habit.log 动作。
        - 【纪念日、订阅与保质期】：提到生日、结婚纪念日、倒数日、会员自动续费或食品证件保质期时，输出 anniversary.create 动作。
        - 【出门清单】：提到“出门清单加上X”、“出门必带X”时，输出 departure.add 动作。
        - 【生活档案】：提到宠物驱虫/疫苗/洗澡/体重（domain=pet）、车辆加油/充电/保养/里程（domain=vehicle）、宝宝身高体重/里程碑（domain=child）、技能练习打卡（domain=skill）、重要证件登记（domain=document）、人生大事筹备（domain=event）时，输出 life.record 动作。
        - 识别到针对已有记录改金额、改标题时，输出对应的 expense.update 或 todo.update。
        - 提到“X放哪了”、“查找X”等检索请求，以及“上周花了多少”、“今天有什么安排”、“最近消费趋势怎么样”等统计/趋势/日程问句时，输出 query.lookup 动作，target 填完整问句或关键词。
        - 【大模型决策输出】：若输入是粘贴的大模型回复（含「行动待办/下一步/落地动作」清单），为每条行动待办输出一个 todo.create（detail 填「AI 决策导入」），决策全文输出一个 memo.inbox。
        - 完全无法归类时输出一个收集箱 memo.inbox 动作。
        """
        return prompt
    }

    // MARK: - 规则兜底路径

    /// 规则兜底总入口。
    ///
    /// P1-4 修复：组合输入（「完成晨跑打卡，顺便喝了500ml水」）先按强分隔符切子句，
    /// 每个子句独立走「单意图优先级链」，互不吞并——此前操作类命中即 return，
    /// 后半句的动作被直接丢弃。
    ///
    /// - Parameter preferredCapability: 用户点选的意图（预填写路径）。
    ///   指定时优先产出该能力；产出不了则按该能力预填一张参数草稿卡。
    static func rulePlan(_ text: String, preferredCapability: ActionCapability? = nil) -> [PlannedAction] {
        // 大模型决策输出必须在切子句之前整段识别——多行决策文被切碎后就认不出来了
        if preferredCapability == nil,
           LifeEventTaskPlanningEngine.looksLikeAIDecisionOutput(text) {
            return aiDecisionActions(from: text)
        }

        let clauses = OmniboxClauseSplitter.split(text)
        var actions: [PlannedAction] = []

        for clause in clauses {
            actions.append(contentsOf: singleClauseActions(clause))
        }

        // 用户点选意图：优先保留该能力的动作；都没有时按该能力预填草稿（预填写语义）
        if let preferredCapability {
            let preferred = actions.filter { $0.capability == preferredCapability }
            if !preferred.isEmpty {
                actions = preferred
            } else {
                actions = [prefillDraftAction(capability: preferredCapability, text: text)]
            }
        }

        // 跨域联动：同批记账挂到待办/生活档案的依赖上（拓扑序）
        let expenseIDs = actions.filter { $0.capability == .expenseCreate }.map(\.id)
        if !expenseIDs.isEmpty {
            for index in actions.indices
            where actions[index].dependsOn.isEmpty
                && (actions[index].capability == .todoCreate || actions[index].capability == .lifeRecord) {
                actions[index].dependsOn = expenseIDs
            }
        }

        // 收集箱兜底：无法归类时永不报错，全部落收集箱（Flomo 原则）
        if actions.isEmpty {
            let memo = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memo.isEmpty {
                actions.append(PlannedAction(
                    capability: .memoInbox,
                    params: ["memo": String(memo.prefix(500))],
                    confidence: 0.9,
                    summary: L10n.tr("收入收集箱：") + String(memo.prefix(40))
                ))
            }
        }
        return actions
    }

    /// 单子句的意图优先级链：修改类 > 操作类 > 生活记录类 > 创建类，命中即返回。
    /// 单句单意图假设成立（组合输入已在外层切开），保留优先级防止
    /// 「取消会议提醒」同时生成待办这类误报。
    private static func singleClauseActions(_ text: String) -> [PlannedAction] {
        // 0. 修改类（P1-3）：「把那笔账改成30」「待办改到后天」
        if let expenseUpdate = extractExpenseUpdateAction(from: text) {
            return [expenseUpdate]
        }
        if let todoUpdate = extractTodoUpdateAction(from: text) {
            return [todoUpdate]
        }

        // 0.1 操作类指令：完成/取消/推迟/查询等动作明确，避免被误判成新建或普通备忘
        if let complete = Self.extractTodoComplete(from: text) {
            return [complete]
        }
        if let cancel = Self.extractTodoCancel(from: text) {
            return [cancel]
        }
        if let snooze = Self.extractReminderSnooze(from: text) {
            return [snooze]
        }
        if let lookup = Self.extractQueryLookup(from: text) {
            return [lookup]
        }

        // 0.2 全域生活记录精确提取（收纳 / 出门清单 / 习惯与服药 / 纪念日与订阅保质期）
        if let storage = Self.extractStorageRecord(from: text) {
            return [storage]
        }
        if let departure = Self.extractDepartureItem(from: text) {
            return [departure]
        }
        if let habitOrMed = Self.extractHabitOrMedicationLog(from: text) {
            return [habitOrMed]
        }
        if let anniversary = Self.extractAnniversaryOrExpiry(from: text) {
            return [anniversary]
        }

        // 0.4 纯饮水/饮品摄入检测（如“喝了500ml水”、“喝了一杯冰美式”）
        if let waterAction = Self.extractWaterRecord(from: text) {
            return [waterAction]
        }

        // 0.45 食物热量视觉识别提取（由食物照片解析出的【食物与热量识别】）
        if let foodAction = Self.extractFoodRecordFromRecognition(text) {
            return [foodAction]
        }

        // 0.5 纯饮食摄入陈述检测：若用户陈述早饭/午饭/晚饭吃了/喝了什么，且不含花费/金额词时，直接生成 food.record 饮食记录
        if Self.isPureMealStatement(text) {
            return [Self.makeFoodRecordAction(from: text)]
        }

        // 0.6 垂类生活档案检测（宠物/爱车/育儿/技能/证件/大事；若同时含加油/买猫粮等金额，与下方记账并存）
        let lifeAction = Self.extractLifeRecord(from: text)
        if let lifeAction, !Self.hasExplicitMoneyExpression(in: text) {
            return [lifeAction]
        }

        var actions: [PlannedAction] = []

        // 1. 记账：优先按短信/订单截图结构化模板提取（最高置信），再复用既有自然语言解析器（支持一句话多笔），最后宽松正则兜底
        if let structured = Self.extractStructuredExpense(from: text) {
            actions.append(structured)
        } else {
            let parsedItems = ExpenseNaturalLanguageParser.parseMulti(text, defaultCurrency: ExpenseCurrency.preferred())
            if !parsedItems.isEmpty {
                for parsed in parsedItems {
                    var params: [String: String] = [
                        "amount": String(format: "%.2f", parsed.amount),
                        "isIncome": parsed.isIncome ? "true" : "false",
                        "category": parsed.category.rawValue,
                        "title": parsed.title
                    ]
                    if parsed.isForeignCurrency, let foreignAmt = parsed.foreignAmount {
                        params["currency"] = parsed.currency.rawValue
                        params["foreignAmount"] = String(format: "%.2f", foreignAmt)
                        params["exchangeRate"] = String(format: "%.6f", parsed.exchangeRateToCNY ?? parsed.currency.currentRateToCNY)
                    }
                    if parsedItems.count > 1 {
                        params["dateISO"] = Self.dateTimeFormatter.string(from: parsed.date)
                    }
                    actions.append(PlannedAction(
                        capability: .expenseCreate,
                        params: params,
                        confidence: parsedItems.count > 1 ? 0.78 : 0.8,
                        confidenceReason: parsedItems.count > 1 ? "已从多笔消费中拆分" : nil,
                        summary: Self.summary(for: .expenseCreate, params: params)
                    ))
                }
            } else if let amount = Self.extractLooseAmount(from: text) {
                let isIncome = Self.containsAny(text, ["收到", "入账", "工资", "报销", "退款", "红包", "收入"])
                let category = Self.guessCategory(from: text)
                let title = Self.guessExpenseTitle(from: text)
                var params = [
                    "amount": String(format: "%.2f", amount),
                    "isIncome": isIncome ? "true" : "false",
                    "category": category.rawValue,
                    "title": title
                ]
                if let date = Self.extractTransactionDate(from: text) {
                    params["dateISO"] = Self.dateTimeFormatter.string(from: date)
                }
                actions.append(PlannedAction(
                    capability: .expenseCreate,
                    params: params,
                    confidence: 0.55,
                    confidenceReason: "松散匹配到金额，建议核对分类与金额",
                    summary: Self.summary(for: .expenseCreate, params: params)
                ))
            }
        }

        // 2. 待办：取件码 / 相对时间关键词 / 保修与收货意图
        if let parcel = Self.extractParcelTodo(from: text) {
            actions.append(parcel)
        }
        if let due = Self.extractRelativeDue(from: text) {
            var params: [String: String] = [
                "title": due.title,
                "dueAtDays": String(due.days)
            ]
            if let time = due.time { params["dueAtTime"] = time }
            if !due.detail.isEmpty { params["detail"] = due.detail }
            actions.append(PlannedAction(
                capability: .todoCreate,
                params: params,
                confidence: 0.65,
                confidenceReason: "根据相对时间词推测，建议核对截止日期",
                summary: Self.summary(for: .todoCreate, params: params)
            ))
        }
        if text.contains("保修") {
            let product = Self.guessExpenseTitle(from: text)
            let params: [String: String] = [
                "title": "\(product)保修期到期检查",
                "detail": "来源：投喂口识别到保修信息，默认 1 年保修期",
                "dueAtDays": "365"
            ]
            actions.append(PlannedAction(
                capability: .todoCreate,
                params: params,
                confidence: 0.58,
                confidenceReason: "根据保修关键词推测，默认1年期",
                summary: Self.summary(for: .todoCreate, params: params)
            ))
        }

        // 2.5 若存在车务/宠物等生活档案动作且同时命中了记账（如“车子加了300块95号汽油”），联动挂依赖
        if var lifeAction {
            lifeAction.dependsOn = actions.filter { $0.capability == .expenseCreate }.map(\.id)
            actions.append(lifeAction)
        }
        return actions
    }

    /// 修改类动作构造：参数键与执行器（executeExpenseUpdate / executeTodoUpdate）严格一致
    static func extractExpenseUpdateAction(from text: String) -> PlannedAction? {
        guard let update = OmniboxUpdateExtractor.extractExpenseUpdate(from: text) else { return nil }
        var params: [String: String] = ["target": update.target]
        if !update.newAmount.isEmpty { params["newAmount"] = update.newAmount }
        if let newTitle = update.newTitle, !newTitle.isEmpty { params["newTitle"] = newTitle }
        return PlannedAction(
            capability: .expenseUpdate,
            params: params,
            confidence: 0.85,
            summary: Self.summary(for: .expenseUpdate, params: params)
        )
    }

    static func extractTodoUpdateAction(from text: String) -> PlannedAction? {
        guard let update = OmniboxUpdateExtractor.extractTodoUpdate(from: text) else { return nil }
        var params: [String: String] = ["target": update.target]
        if let newTitle = update.newTitle, !newTitle.isEmpty { params["newTitle"] = newTitle }
        if let days = update.dueAtDays { params["dueAtDays"] = String(days) }
        if let time = update.dueAtTime { params["dueAtTime"] = time }
        return PlannedAction(
            capability: .todoUpdate,
            params: params,
            confidence: 0.85,
            summary: Self.summary(for: .todoUpdate, params: params)
        )
    }

    /// 按用户点选的意图预填一张草稿卡（LLM 与规则都产出不了该能力时的兜底）。
    /// 参数尽量从原文复用既有提取器填上，填不出的留空给确认卡编辑；默认不勾选，等人核对。
    static func prefillDraftAction(capability: ActionCapability, text: String) -> PlannedAction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: String] = [:]
        switch capability {
        case .expenseCreate:
            if let amount = Self.extractLooseAmount(from: trimmed) {
                params["amount"] = String(format: "%.2f", amount)
                params["isIncome"] = Self.containsAny(trimmed, ["收到", "入账", "工资", "报销", "退款", "红包", "收入"]) ? "true" : "false"
                params["category"] = Self.guessCategory(from: trimmed).rawValue
                params["title"] = Self.guessExpenseTitle(from: trimmed)
            } else {
                params = ["amount": "", "isIncome": "false", "category": ExpenseCategory.other.rawValue, "title": String(trimmed.prefix(12))]
            }
        case .todoCreate:
            params = ["title": String(trimmed.prefix(24)), "detail": trimmed]
        case .memoInbox:
            params = ["memo": String(trimmed.prefix(500))]
        case .foodRecord:
            return Self.makeFoodRecordAction(from: trimmed)
        case .waterRecord:
            params = ["beverageType": "白开水", "volumeML": "250"]
        default:
            // 修改/操作/查询/生活记录类：原文做匹配词，细节留确认卡编辑
            params = [
                "target": trimmed,
                "title": String(trimmed.prefix(24)),
                "name": String(trimmed.prefix(24)),
                "detail": trimmed
            ]
        }
        return PlannedAction(
            capability: capability,
            params: params,
            confidence: 0.5,
            confidenceReason: "按所选意图预填，请核对参数",
            isSelected: false,
            summary: "\(capability.displayName)：\(String(trimmed.prefix(24)))"
        )
    }

    // MARK: - 参数补全工具（确认卡编辑时也调用）

    static func summary(for capability: OmniboxCapability, params: [String: String]) -> String {
        switch capability {
        case .expenseCreate:
            guard let amount = Double(params["amount"] ?? ""), amount > 0 else { return "" }
            let income = params["isIncome"] == "true"
            let category = params["category"] ?? L10n.tr("其它支出")
            let title = params["title"]?.isEmpty == false ? params["title"]! : L10n.tr("未命名事项")
            if let code = params["currency"],
               let currency = ExpenseCurrency(rawValue: code),
               currency != .cny,
               let foreignAmt = Double(params["foreignAmount"] ?? ""),
               foreignAmt > 0 {
                return "\(income ? "+" : "-")¥\(Self.trimAmount(amount))（\(currency.formatAmount(foreignAmt))） · \(category) · \(title)"
            }
            return "\(income ? "+" : "-")¥\(Self.trimAmount(amount)) · \(category) · \(title)"
        case .todoCreate:
            guard let title = params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "" }
            var parts = [title]
            if let iso = params["dueAtISO"], let date = parseParamDate(iso) {
                parts.append(date.formatted(date: .abbreviated, time: .shortened))
            } else if let days = Int(params["dueAtDays"] ?? ""), days > 0 {
                parts.append("\(days) 天后")
            }
            if let time = params["dueAtTime"], !time.isEmpty {
                parts.append(time)
            }
            return parts.joined(separator: " · ")
        case .memoInbox:
            guard let memo = params["memo"]?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty else { return "" }
            return L10n.tr("收入收集箱：") + String(memo.prefix(40))
        case .foodRecord:
            let name = params["foodName"] ?? "餐食"
            let slot = params["mealSlot"] ?? "餐饮"
            let cal = params["calories"] != nil ? " · 约 \(params["calories"]!)千卡" : ""
            return "🍽️ 记录饮食：\(name)（\(slot)\(cal)）"
        case .waterRecord:
            let bevLabel = params["customName"] ?? params["beverageType"] ?? "白开水"
            let vol = Double(params["volumeML"] ?? "") ?? 250
            let bevType = HydrationBeverageType.fromLabel(params["beverageType"] ?? bevLabel)
            let eff = Int((vol * bevType.defaultHydrationFactor).rounded())
            return "💧 记录饮水：\(bevLabel) \(Int(vol))ml（折算补水 \(eff)ml）"
        case .storageRecord:
            let name = params["name"] ?? "物品"
            let loc = params["location"] ?? "默认位置"
            let room = params["roomArea"].flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
            let isMed = params["isMedicine"] == "true"
            return "📦 \(isMed ? "常备药入库" : "物品收纳")：\(name) → \(room)\(loc)"
        case .habitLog:
            let target = params["target"] ?? "打卡项"
            let isMed = params["kind"] == "medication"
            let dosage = params["dosage"].flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "\(isMed ? "💊 服药打卡" : "✅ 习惯打卡")：\(target)\(dosage)"
        case .anniversaryCreate:
            let title = params["title"] ?? "重要日子"
            let cat = params["category"] ?? "纪念日"
            let dateStr = params["targetDate"].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            let priceStr = params["price"].flatMap { $0.isEmpty ? nil : " · ¥\($0)" } ?? ""
            return "🎂 新建\(cat)：\(title)\(dateStr)\(priceStr)"
        case .departureAdd:
            let title = params["title"] ?? "随身物品"
            let scene = params["scene"] ?? "工作通勤"
            let loc = params["location"].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            return "🚪 出门清单：\(title)（\(scene)\(loc)）"
        case .lifeRecord:
            let domain = params["domain"] ?? "pet"
            let title = params["title"] ?? "生活记录"
            let detail = params["detail"].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            let valStr = params["value"].flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let prefix: String = switch domain {
            case "pet": "🐾 宠物养护"
            case "vehicle": "🚗 爱车管家"
            case "child": "👶 育儿成长"
            case "skill": "🎯 技能练习"
            case "document": "🪪 重要证件"
            case "event": "🌟 人生大事"
            default: "📋 生活档案"
            }
            return "\(prefix)：\(title)\(detail)\(valStr)"
        default:
            return ActionParser.generateSummary(for: capability, params: params)
        }
    }

    static func trimAmount(_ amount: Double) -> String {
        amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(amount))
            : String(format: "%.2f", amount)
    }

    // MARK: - 规则提取器

    /// 匹配完成待办动作：把[X]完成 / 完成[X] / 标记完成[X]
    static func extractTodoComplete(from text: String) -> PlannedAction? {
        let patterns = [
            "(?:把|将)?\\s*(.+?)\\s*(?:标记为?已?完成|搞定了?|做好了?|已完成)$",
            "^(?:完成|办结|做完|搞定)\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target]
                    return PlannedAction(
                        capability: .todoComplete,
                        params: params,
                        confidence: 0.9,
                        summary: Self.summary(for: .todoComplete, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 匹配取消/删除待办动作：取消[X] / 删掉[X] / 不要提醒[X]
    static func extractTodoCancel(from text: String) -> PlannedAction? {
        let patterns = [
            "^(?:取消|删除|删掉|去掉|撤销)\\s*(?:待办|事项|提醒)?\\s*(.+)",
            "^(?:不要|别)\\s*提醒我?\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target]
                    return PlannedAction(
                        capability: .todoCancel,
                        params: params,
                        confidence: 0.85,
                        summary: Self.summary(for: .todoCancel, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 匹配推迟提醒动作：推迟[X] / 顺延[X] / 稍后提醒[X]
    static func extractReminderSnooze(from text: String) -> PlannedAction? {
        let patterns = [
            "^(?:推迟|顺延|延后|稍后提醒)\\s*(.+?)(?:(\\d+\\s*(?:分钟|小时|天))|到明早)?$",
            "^(?:把|将)?\\s*(.+?)\\s*(?:推迟|顺延|延后)(?:(\\d+\\s*(?:分钟|小时|天))|到明早)?$"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                var duration = "1小时"
                if first.numberOfRanges > 2 && first.range(at: 2).location != NSNotFound {
                    let dur = ns.substring(with: first.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dur.isEmpty { duration = dur }
                }
                if !target.isEmpty && target.count < 40 {
                    let params = ["target": target, "duration": duration]
                    return PlannedAction(
                        capability: .reminderSnooze,
                        params: params,
                        confidence: 0.85,
                        summary: Self.summary(for: .reminderSnooze, params: params)
                    )
                }
            }
        }
        return nil
    }

    /// 短信账单 / 订单截图的结构化提取：模板化金额关键词 + 商户名 + 交易时间
    /// 覆盖：银行/支付宝/微信扣款短信（消费/支出/向XX支付）、电商订单页（实付款/支付金额/合计）
    static func extractStructuredExpense(from text: String) -> PlannedAction? {
        guard let amount = Self.extractExplicitPayAmount(from: text) else { return nil }

        let isIncome = Self.containsAny(text, ["退款", "到账", "入账", "收入", "工资", "红包", "报销"])
        let merchant = Self.extractMerchant(from: text)
        let category: ExpenseCategory = isIncome
            ? (text.contains("工资") ? .income : .otherIncome)
            : Self.guessCategory(from: text)
        let title = merchant ?? Self.guessExpenseTitle(from: text)

        var params: [String: String] = [
            "amount": String(format: "%.2f", amount),
            "isIncome": isIncome ? "true" : "false",
            "category": category.rawValue,
            "title": title
        ]
        if let date = Self.extractTransactionDate(from: text) {
            params["dateISO"] = Self.dateTimeFormatter.string(from: date)
        }
        // 短信/订单模板命中，结构化程度高，默认勾选执行
        return PlannedAction(
            capability: .expenseCreate,
            params: params,
            confidence: 0.88,
            summary: Self.summary(for: .expenseCreate, params: params)
        )
    }

    /// 当原文包含明确外币（如“1500日元”、“$25”），而端侧 LLM 仅提取了原币数字时，自动补齐币种与人民币折算
    private static func enrichForeignCurrencyIfNeeded(actions: [PlannedAction], sourceText: String) -> [PlannedAction] {
        guard let explicit = ExpenseCurrency.detectExplicitCurrency(in: sourceText),
              explicit != .cny else {
            return actions
        }
        let parsed = ExpenseNaturalLanguageParser.parse(sourceText, defaultCurrency: explicit)
        return actions.map { action in
            guard action.capability == .expenseCreate,
                  action.params["currency"] == nil,
                  let rawAmt = Double(action.params["amount"] ?? ""),
                  rawAmt > 0 else {
                return action
            }
            var updated = action
            let rate = explicit.currentRateToCNY
            // 若 LLM 填的是外币原币数值（或未折算），自动折算为人民币并记录外币原值
            let foreignAmt: Double
            if let parsedForeign = parsed?.foreignAmount, abs(rawAmt - parsedForeign) < 0.01 {
                foreignAmt = parsedForeign
            } else {
                foreignAmt = rawAmt
            }
            let cnyAmt = explicit.convertToCNY(foreignAmt, rate: rate)
            updated.params["currency"] = explicit.rawValue
            updated.params["foreignAmount"] = String(format: "%.2f", foreignAmt)
            updated.params["exchangeRate"] = String(format: "%.6f", rate)
            updated.params["amount"] = String(format: "%.2f", cnyAmt)
            if let cleanTitle = parsed?.title, !cleanTitle.isEmpty {
                updated.params["title"] = cleanTitle
            }
            updated.summary = Self.summary(for: .expenseCreate, params: updated.params)
            return updated
        }
    }

    /// 按可信度从高到低匹配「明确的支付金额」表述
    private static func extractExplicitPayAmount(from text: String) -> Double? {
        let patterns: [String] = [
            // 订单截图：实付款 ¥59.90 / 支付金额：59.9元 / 合计 ¥xx
            "(?:实付款?|支付金额|付款金额|订单金额|应付金额|合计|总计|交易金额|扣款金额)[^0-9¥￥]{0,6}[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)",
            // 银行/支付宝短信：消费99.00元（美团） / 支出100元 / 扣款xx元
            "(?:消费|支出|扣款|付款|缴纳|缴费)[^0-9]{0,12}([0-9]+(?:\\.[0-9]+)?)\\s*元?",
            // 向XX支付99元 / 转账给XX 99元
            "(?:向|给)\\s*[^，。,\\s]{2,15}\\s*(?:支付|转账|付款)\\s*[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)",
            // 支付宝通知：您有一笔99.00元的交易
            "一笔\\s*[¥￥]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*元",
            // 退款/到账短信：退款99.00元 / 到账100元
            "(?:退款|到账|入账|收入)[^0-9]{0,8}([0-9]+(?:\\.[0-9]+)?)\\s*元"
        ]
        for pattern in patterns {
            if let value = Self.firstCapturedNumber(pattern, in: text), value > 0 {
                return value
            }
        }
        return nil
    }

    /// 从短信模板或订单页里提取商户名
    private static func extractMerchant(from text: String) -> String? {
        let patterns: [String] = [
            "在「([^」]{2,12})」",                 // 在「美团」消费
            "「([^」]{2,12})」",
            "（([^）]{2,12})）\\s*$",              // 银行短信尾部：消费99.00元（美团）
            "消费[0-9.]+元（([^）]{2,12})）",
            "(?:向|给)\\s*([^，。,\\s]{2,15}?)\\s*(?:支付|转账|付款)",
            "在([^，。,\\s]{2,10}?)(?:消费|支付|购物|下单|购买)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespaces)
                // 排除明显不是商户的捕获（纯数字、银行短信签名残留）
                if candidate.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
                   !candidate.contains("银行"), candidate.count >= 2 {
                    return candidate
                }
            }
        }
        return nil
    }

    /// 提取交易时间（短信/截图里的 MM月dd日 HH:mm、yyyy-MM-dd HH:mm 等）
    /// 转发到 AssistantCore 单一实现（小票解析共用同一份正则，避免漂移）
    static func extractTransactionDate(from text: String) -> Date? {
        TransactionDateExtractor.extract(from: text)
    }

    private static func firstCapturedNumber(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else {
            return nil
        }
        return value
    }

    /// 万能框的宽松金额兜底。主解析器失败时才走到这里，因此只覆盖最常见的写法。
    /// 注意与 `ExpenseNaturalLanguageParser` 保持同样的两条约束：
    /// 千分位逗号要先剥掉、数字要有边界断言，否则 "1,250元" 会被截成 "250"。
    static func extractLooseAmount(from text: String) -> Double? {
        let normalized = ExpenseNaturalLanguageParser.normalizeForLooseExtraction(text)
        let patterns = [
            "[¥￥]\\s*([0-9]+(?:\\.[0-9]+)?)",
            "(?<![0-9.．])([0-9]+(?:\\.[0-9]+)?)(?![0-9])\\s*(?:元|块钱|块)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: normalized.utf16.count)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: normalized),
               let value = Double(normalized[range]), value > 0 {
                return value
            }
        }
        return nil
    }

    /// 判断是否为纯饮食/用餐摄入陈述（没有提到花费金额）
    static func isPureMealStatement(_ text: String) -> Bool {
        let mealKeywords = [
            "早饭吃了", "早餐吃了", "午饭吃了", "午餐吃了", "晚饭吃了", "晚餐吃了", "夜宵吃了",
            "早饭喝了", "早餐喝了", "午饭喝了", "午餐喝了", "晚饭喝了", "晚餐喝了",
            "早饭吃", "早餐吃", "午饭吃", "午餐吃", "晚饭吃", "晚餐吃", "夜宵吃",
            "吃了点", "喝了点", "吃了个", "吃了", "喝了", "早饭", "早餐", "午饭", "午餐", "晚饭", "晚餐", "夜宵"
        ]
        guard containsAny(text, mealKeywords) else { return false }
        let expenseKeywords = ["花了", "花掉", "付了", "用去", "支出", "消费了", "消费", "共计", "元", "块钱", "块", "¥", "￥", "$", "买", "点外卖", "账单", "报销"]
        return !containsAny(text, expenseKeywords)
    }

    private static func guessCategory(from text: String) -> ExpenseCategory {
        // 先按常见商户/平台名匹配（短信与订单截图的商家名是最强分类信号）
        let merchantMapping: [(ExpenseCategory, [String])] = [
            (.food, ["美团", "饿了么", "麦当劳", "肯德基", "星巴克", "瑞幸", "必胜客", "海底捞", "喜茶", "蜜雪", "外卖"]),
            (.transport, ["滴滴", "高德", "花小猪", "中石油", "中石化", "12306", "铁路", "航空", "地铁", "ETC", "停车"]),
            (.shopping, ["京东", "淘宝", "天猫", "拼多多", "唯品会", "苏宁", "抖音商城", "闲鱼"]),
            (.medical, ["医院", "药房", "药店", "诊所", "体检"]),
            (.entertainment, ["爱奇艺", "腾讯视频", "优酷", "网易云音乐", "QQ音乐", "电影院", "猫眼", "大麦"]),
            (.digital, ["苹果", "Apple", "小米", "华为", "荣耀", "OPPO", "vivo", "大疆"]),
            (.living, ["话费", "流量", "宽带", "水电", "燃气", "物业", "中国移动", "中国联通", "中国电信"])
        ]
        for (category, keywords) in merchantMapping where containsAny(text, keywords) {
            return category
        }
        let mapping: [(ExpenseCategory, [String])] = [
            (.food, ["餐", "外卖", "吃", "奶茶", "咖啡", "饭"]),
            (.transport, ["打车", "地铁", "公交", "加油", "火车", "机票", "高铁"]),
            (.digital, ["电饭煲", "手机", "电脑", "耳机", "平板", "家电", "数码", "相机"]),
            (.shopping, ["买", "购物", "订单", "下单"]),
            (.medical, ["药", "医院", "体检", "挂号"]),
            (.entertainment, ["电影", "游戏", "演出", "门票"]),
            (.pets, ["猫", "狗", "宠物", "猫粮", "狗粮"]),
            (.living, ["水电", "燃气", "物业", "日用品"])
        ]
        for (category, keywords) in mapping where containsAny(text, keywords) {
            return category
        }
        return .other
    }

    private static func guessExpenseTitle(from text: String) -> String {
        // 取第一个 2~12 字的商品/事项词（简单启发：截取金额之后的短片段）
        if let regex = try? NSRegularExpression(pattern: "(?:买了?|购入|下单|订单[：:]?)\\s*([^，。,\\.\\n\\s¥￥0-9]{2,12})"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           match.range(at: 1).location != NSNotFound,
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "¥", with: " ")
            .replacingOccurrences(of: "￥", with: " ")
        let tokens = cleaned.split(whereSeparator: { " ，。,.".contains($0) })
        return tokens.first.map { String($0.prefix(12)) } ?? L10n.tr("投喂记录")
    }

    private static func extractParcelTodo(from text: String) -> PlannedAction? {
        guard let regex = try? NSRegularExpression(pattern: "取件码[^0-9]{0,6}([0-9]{4,8})"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let code = String(text[range])
        let params: [String: String] = [
            "title": "取快递（取件码 \(code)）",
            "detail": text.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return PlannedAction(
            capability: .todoCreate,
            params: params,
            confidence: 0.85,
            summary: Self.summary(for: .todoCreate, params: params)
        )
    }

    private static func extractRelativeDue(from text: String) -> (title: String, days: Int, time: String?, detail: String)? {
        guard containsAny(text, ["提醒", "待办", "记得", "收货", "到期", "还款", "预约", "别忘", "保修", "发货"]) else { return nil }

        var days = 1
        if let regex = try? NSRegularExpression(pattern: "([0-9]+)\\s*天(之|以)?后"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           match.range(at: 1).location != NSNotFound,
           let range = Range(match.range(at: 1), in: text),
           let value = Int(text[range]) {
            days = value
        } else if text.contains("后天") {
            days = 2
        } else if text.contains("明天") {
            days = 1
        }

        var time: String? = nil
        if let regex = try? NSRegularExpression(pattern: "([01]?[0-9]|2[0-3]):[0-5][0-9]"),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range, in: text) {
            time = String(text[range])
        }

        let title = Self.guessExpenseTitle(from: text)
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, days, time, String(detail.prefix(200)))
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 动作参数里交易时间的标准格式（yyyy-MM-dd HH:mm）
    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 解析动作参数中的 dateISO（确认卡展示与执行器落库共用）
    static func parseParamDate(_ iso: String?) -> Date? {
        guard let iso = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty else { return nil }
        return dateTimeFormatter.date(from: iso)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()

    // MARK: - 全域数据模型规则抽取与 LLM 防幻觉增强

    // MARK: - 食物图像视觉识别与饮食记录构造

    static func detectFoodInImage(_ image: UIImage, userText: String?) async -> DetectedFoodInfo? {
        let candidates = await FoodVisionService.shared.recognize(in: image)
        let detectedDishes = await MainActor.run {
            FoodVisionService.shared.detectedMealDishes
        }
        let rawClassifications = await MainActor.run {
            FoodVisionService.shared.rawClassifications
        }

        let trimmedText = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let thumbnail = image.scaledDown(maxDimension: 480).jpegData(compressionQuality: 0.7)

        // 1. 如果已通过 Vision 映射到具体的食物库菜品（如披萨、汉堡、拉面、米饭、炒菜等）
        if !candidates.isEmpty {
            if let meal = FoodCalorieEstimator.estimateMeal(from: candidates, detectedDishes: detectedDishes) {
                if !trimmedText.isEmpty,
                   let hinted = FoodCalorieEstimator.estimateMeal(fromHint: trimmedText) {
                    return DetectedFoodInfo(estimate: hinted, thumbnailData: thumbnail)
                }
                return DetectedFoodInfo(estimate: meal, thumbnailData: thumbnail)
            }
            if let single = FoodCalorieEstimator.estimate(from: candidates) {
                return DetectedFoodInfo(estimate: single, thumbnailData: thumbnail)
            }
        }

        // 2. 如果视觉库未命中具体菜品，但用户文本明确说明了吃了什么（如“午餐吃了这碗拌面”）
        if !trimmedText.isEmpty,
           let hinted = FoodCalorieEstimator.estimateMeal(fromHint: trimmedText) {
            return DetectedFoodInfo(estimate: hinted, thumbnailData: thumbnail)
        }

        // 3. 泛类食物检测（Vision 认出了是食物/菜肴/果蔬/饮品，但未精确映射到具体库条目）
        let genericFoodKeywords = ["food", "dish", "meal", "cuisine", "delicacy", "fast_food", "snack", "produce", "baked_goods", "beverage", "drink"]
        let hasGenericFoodSignal = rawClassifications.contains { item in
            let id = item.identifier.lowercased()
            return genericFoodKeywords.contains(where: { id.contains($0) }) && item.confidence >= 0.20
        }

        if hasGenericFoodSignal {
            let defaultFood = FoodItem(
                id: "meal_generic",
                name: "餐食",
                nameEn: "Meal",
                caloriesPer100g: 150,
                category: .staple,
                visionIdentifiers: [],
                aliases: ["餐食", "食物"]
            )
            let estimate = FoodCalorieEstimate(
                food: defaultFood,
                portion: .regular,
                confidence: 0.45,
                fullPortionCaloriesOverride: 400,
                customDisplayName: "餐食"
            )
            return DetectedFoodInfo(estimate: estimate, thumbnailData: thumbnail)
        }

        return nil
    }

    static func extractFoodRecordFromRecognition(_ text: String) -> PlannedAction? {
        guard text.contains("【食物与热量识别】") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() where line.contains("【食物与热量识别】") {
            if i + 1 < lines.count {
                let content = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let comp = content.components(separatedBy: "·")
                let foodName = comp.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !foodName.isEmpty else { continue }

                var caloriesStr: String? = nil
                if comp.count > 1 {
                    let calPart = comp[1]
                    if let num = calPart.range(of: "[0-9]+", options: .regularExpression) {
                        caloriesStr = String(calPart[num])
                    }
                }

                let currentHour = Calendar.current.component(.hour, from: .now)
                let slot: String
                if containsAny(text, ["早饭", "早餐"]) { slot = "早餐" }
                else if containsAny(text, ["午饭", "午餐", "午"]) { slot = "午餐" }
                else if containsAny(text, ["晚饭", "晚餐", "晚"]) { slot = "晚餐" }
                else if containsAny(text, ["夜宵", "宵夜"]) { slot = "夜宵" }
                else if containsAny(text, ["加餐", "下午茶"]) { slot = "加餐" }
                else {
                    if currentHour >= 5 && currentHour < 10 { slot = "早餐" }
                    else if currentHour >= 10 && currentHour < 15 { slot = "午餐" }
                    else if currentHour >= 15 && currentHour < 21 { slot = "晚餐" }
                    else { slot = "加餐" }
                }

                var params: [String: String] = [
                    "foodName": foodName,
                    "mealSlot": slot,
                    "rawText": text
                ]
                if let caloriesStr {
                    params["calories"] = caloriesStr
                } else if let estimate = FoodCalorieEstimator.estimateMeal(fromHint: foodName) {
                    params["calories"] = "\(Int(estimate.fullPortionCalories))"
                }

                let isGeneric = foodName == "餐食"
                let confidence = isGeneric ? 0.5 : 0.9

                return PlannedAction(
                    capability: .foodRecord,
                    params: params,
                    confidence: confidence,
                    summary: Self.summary(for: .foodRecord, params: params)
                )
            }
        }
        return nil
    }

    static func makeFoodRecordAction(from text: String) -> PlannedAction {
        let currentHour = Calendar.current.component(.hour, from: .now)
        let slot: String
        if containsAny(text, ["早饭", "早餐"]) { slot = "早餐" }
        else if containsAny(text, ["午饭", "午餐", "午"]) { slot = "午餐" }
        else if containsAny(text, ["晚饭", "晚餐", "晚"]) { slot = "晚餐" }
        else if containsAny(text, ["夜宵", "宵夜"]) { slot = "夜宵" }
        else if containsAny(text, ["加餐", "下午茶"]) { slot = "加餐" }
        else {
            if currentHour >= 5 && currentHour < 10 { slot = "早餐" }
            else if currentHour >= 10 && currentHour < 15 { slot = "午餐" }
            else if currentHour >= 15 && currentHour < 21 { slot = "晚餐" }
            else { slot = "加餐" }
        }

        var params: [String: String] = [
            "mealSlot": slot,
            "rawText": text
        ]
        if let estimate = FoodCalorieEstimator.estimateMeal(fromHint: text) {
            params["foodName"] = estimate.displayName
            params["calories"] = "\(Int(estimate.fullPortionCalories))"
            params["foodID"] = estimate.food.id
        } else {
            params["foodName"] = text
        }
        return PlannedAction(
            capability: .foodRecord,
            params: params,
            confidence: 0.9,
            summary: Self.summary(for: .foodRecord, params: params)
        )
    }

    static func hasExplicitMoneyExpression(in text: String) -> Bool {
        if extractLooseAmount(from: text) != nil { return true }
        let moneyUnits = ["元", "块钱", "块", "¥", "￥", "$", "USD", "EUR", "JPY", "HKD", "英镑", "日元", "美元"]
        return containsAny(text, moneyUnits)
    }

    static func sanitizeAndEnrichLLMActions(actions: [PlannedAction], sourceText: String) -> [PlannedAction] {
        var result: [PlannedAction] = []
        let hasMoney = hasExplicitMoneyExpression(in: sourceText)

        for action in actions {
            // 防幻觉卫兵：当原文完全未出现任何金额/货币符号，而模型幻觉输出了 expense.create 时，强制由规则纠偏
            if action.capability == .expenseCreate && !hasMoney {
                let corrected = rulePlan(sourceText)
                if !corrected.isEmpty {
                    result.append(contentsOf: corrected)
                    continue
                }
            }
            // 降级拦截卫兵：若模型落入 memo.inbox，但规则引擎能从原文中精准提取特定生活记录时，优先使用结构化动作
            if action.capability == .memoInbox {
                if let water = extractWaterRecord(from: sourceText) {
                    result.append(water)
                    continue
                }
                if let food = extractFoodRecordFromRecognition(sourceText) {
                    result.append(food)
                    continue
                }
                if isPureMealStatement(sourceText) {
                    result.append(makeFoodRecordAction(from: sourceText))
                    continue
                }
                if let storage = extractStorageRecord(from: sourceText) {
                    result.append(storage)
                    continue
                }
                if let habit = extractHabitOrMedicationLog(from: sourceText) {
                    result.append(habit)
                    continue
                }
                if let anniv = extractAnniversaryOrExpiry(from: sourceText) {
                    result.append(anniv)
                    continue
                }
                if let dep = extractDepartureItem(from: sourceText) {
                    result.append(dep)
                    continue
                }
                if let life = extractLifeRecord(from: sourceText) {
                    result.append(life)
                    continue
                }
            }
            if action.capability == .foodRecord {
                var updated = action
                if (updated.params["calories"] ?? "").isEmpty {
                    let foodName = updated.params["foodName"] ?? ""
                    if let est = FoodCalorieEstimator.estimateMeal(fromHint: foodName) {
                        updated.params["calories"] = "\(Int(est.fullPortionCalories))"
                        if updated.params["foodID"] == nil {
                            updated.params["foodID"] = est.food.id
                        }
                        updated.summary = Self.summary(for: .foodRecord, params: updated.params)
                    }
                }
                result.append(updated)
                continue
            }
            result.append(action)
        }

        // 车务/宠物等跨域联动：若有记账动作且原文提及加油/洗车/保养等车务，联动产出 life.record
        if result.contains(where: { $0.capability == .expenseCreate }) && !result.contains(where: { $0.capability == .lifeRecord }) {
            if let life = extractLifeRecord(from: sourceText) {
                var linked = life
                linked.dependsOn = result.filter { $0.capability == .expenseCreate }.map(\.id)
                result.append(linked)
            }
        }

        return result
    }

    static func extractWaterRecord(from text: String) -> PlannedAction? {
        guard let parsed = HydrationNaturalLanguageParser.parse(text) else { return nil }
        let params: [String: String] = [
            "beverageType": parsed.beverageType.displayName,
            "volumeML": "\(Int(parsed.volumeML))",
            "customName": parsed.customName
        ]
        return PlannedAction(
            capability: .waterRecord,
            params: params,
            confidence: 0.92,
            summary: Self.summary(for: .waterRecord, params: params)
        )
    }

    /// 大模型决策输出 → 动作组：每条行动项一个待办 + 决策全文落收集箱保底。
    /// 复用 `LifeEventTaskPlanningEngine.parseAIDecisionOutput`（与人生大事导入视图同一解析器）。
    /// `fromAIDecision` 标记供回执区识别，挂「关联到人生大事」入口。
    private static func aiDecisionActions(from text: String) -> [PlannedAction] {
        let parsed = LifeEventTaskPlanningEngine.parseAIDecisionOutput(rawOutput: text)
        var actions: [PlannedAction] = []

        for item in parsed.actionItems {
            let params: [String: String] = [
                "title": item,
                "detail": "AI 决策导入",
                "fromAIDecision": "1",
                "sourceText": "Omnibox投喂·AI决策"
            ]
            actions.append(PlannedAction(
                capability: .todoCreate,
                params: params,
                confidence: 0.88,
                confidenceReason: "识别为大模型决策输出的行动待办",
                summary: "✨ AI 决策待办：\(item)"
            ))
        }

        // Flomo 原则：内容永不丢失——决策全文（截断到收集箱容量）落 memo 保底，
        // 即便行动项提取有遗漏，原文仍可检索。
        actions.append(PlannedAction(
            capability: .memoInbox,
            params: ["memo": String(text.prefix(500)), "fromAIDecision": "1"],
            confidence: 0.85,
            summary: "✨ AI 决策全文已收入集箱"
        ))
        return actions
    }

    static func extractQueryLookup(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 结构化查询意图（汇总/趋势/日程/查找）：「上周花了多少」「今天有什么安排」「最近消费趋势」
        //    解析器自带记账句/祈使句守卫（宁可少解析，不可解析错），命中即整句交查询执行器
        if let insight = QueryInsightEngine.parse(trimmed) {
            let params: [String: String] = [
                "query": trimmed,
                "domain": insight.domain.rawValue,
                "kind": insight.kind.rawValue
            ]
            return PlannedAction(
                capability: .queryLookup,
                params: params,
                confidence: 0.92,
                summary: "🔍 查询：\(trimmed)"
            )
        }

        // 2. 纯关键词查找（「查找发票」这类无领域词的检索）：正则单份在 QueryInsightEngine
        if let target = QueryInsightEngine.extractLookupKeyword(trimmed) {
            let params = ["target": target, "query": trimmed]
            return PlannedAction(
                capability: .queryLookup,
                params: params,
                confidence: 0.9,
                summary: "🔍 查询事项与收纳位置：\(target)"
            )
        }
        return nil
    }

    static func extractStorageRecord(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "(?:把|将)?\\s*(.+?)\\s*(?:放在了?|收在了?|存放在了?|放在|收在|存放于|收纳到)\\s*(.+)",
            "(.+?)\\s*(?:放进|收进|放到了?)\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 2 {
                let name = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let location = ns.substring(with: first.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !location.isEmpty, name.count < 30, location.count < 60 else { continue }

                if containsAny(name, ["会议", "待办", "日程", "提醒", "事情", "任务"]) { continue }

                let rooms = ["主卧", "次卧", "客厅", "书房", "玄关", "厨房", "阳台", "储物间", "洗手间", "卫生间"]
                let room = rooms.first { location.contains($0) || name.contains($0) } ?? "主卧"

                let medWords = ["药", "布洛芬", "阿莫西林", "感冒", "退烧", "消炎", "维生素", "创可贴", "眼药水", "止痛"]
                let isMedicine = medWords.contains { name.contains($0) || location.contains($0) }

                let params: [String: String] = [
                    "name": name,
                    "location": location,
                    "roomArea": room,
                    "isMedicine": isMedicine ? "true" : "false"
                ]
                return PlannedAction(
                    capability: .storageRecord,
                    params: params,
                    confidence: 0.88,
                    summary: Self.summary(for: .storageRecord, params: params)
                )
            }
        }
        return nil
    }

    static func extractDepartureItem(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("出门") || trimmed.contains("带上") || trimmed.contains("随身") else { return nil }
        guard containsAny(trimmed, ["清单", "记得带", "必带", "别忘带", "带上", "带好"]) else { return nil }

        let itemPatterns = [
            "出门(?:清单)?(?:加上|添加|记得带|带上|别忘带)\\s*(.+)",
            "(?:记得带|带上|随身携带)\\s*(.+?)(?:出门)?$"
        ]
        for pattern in itemPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let title = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count < 30 else { continue }
                var scene = "工作通勤"
                if containsAny(trimmed, ["运动", "健身", "跑步"]) { scene = "运动健身" }
                else if containsAny(trimmed, ["旅行", "出差", "机场", "高铁"]) { scene = "出差旅行" }
                else if containsAny(trimmed, ["带娃", "宝宝", "小孩"]) { scene = "带娃出行" }
                else if containsAny(trimmed, ["遛狗", "宠物", "狗"]) { scene = "遛狗随行" }
                else if containsAny(trimmed, ["雨", "伞", "雪"]) { scene = "雨雪出行" }

                let params: [String: String] = [
                    "title": title,
                    "scene": scene
                ]
                return PlannedAction(
                    capability: .departureAdd,
                    params: params,
                    confidence: 0.88,
                    summary: Self.summary(for: .departureAdd, params: params)
                )
            }
        }
        return nil
    }

    static func extractHabitOrMedicationLog(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let medPatterns = [
            "(?:吃了|服用了|服下|服了|喝了)\\s*([^，。,\\s]{1,15}?(?:药|胶囊|冲剂|片|滴眼液|喷雾|维生素|钙片|鱼油|胰岛素))",
            "(?:吃完|服完|喝完)\\s*([^，。,\\s]{1,15}?(?:药|胶囊|冲剂|片|中药|西药))"
        ]
        for pattern in medPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty {
                    let params = ["target": target, "kind": "medication"]
                    return PlannedAction(
                        capability: .habitLog,
                        params: params,
                        confidence: 0.9,
                        summary: Self.summary(for: .habitLog, params: params)
                    )
                }
            }
        }

        if trimmed.contains("打卡") || trimmed.contains("习惯") || (trimmed.contains("完成") && containsAny(trimmed, ["晨跑", "早起", "阅读", "健身", "喝水", "运动", "散步"])) {
            var clean = trimmed
                .replacingOccurrences(of: "打卡", with: "")
                .replacingOccurrences(of: "完成", with: "")
                .replacingOccurrences(of: "搞定", with: "")
                .replacingOccurrences(of: "今日", with: "")
                .replacingOccurrences(of: "今天", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { clean = "日常习惯" }
            let params = ["target": clean, "kind": "habit"]
            return PlannedAction(
                capability: .habitLog,
                params: params,
                confidence: 0.88,
                summary: Self.summary(for: .habitLog, params: params)
            )
        }
        return nil
    }

    static func extractAnniversaryOrExpiry(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsAny(trimmed, ["自动续费", "续费", "订阅"]) {
            let title = guessExpenseTitle(from: trimmed)
            let params = ["title": title, "category": "订阅续费"]
            return PlannedAction(
                capability: .anniversaryCreate,
                params: params,
                confidence: 0.85,
                summary: Self.summary(for: .anniversaryCreate, params: params)
            )
        }

        if containsAny(trimmed, ["过期", "到期", "保质期"]) && containsAny(trimmed, ["药", "水", "奶", "食物", "证件", "护照", "开封"]) {
            let title = guessExpenseTitle(from: trimmed)
            let params = ["title": title, "category": "保质期"]
            return PlannedAction(
                capability: .anniversaryCreate,
                params: params,
                confidence: 0.85,
                summary: Self.summary(for: .anniversaryCreate, params: params)
            )
        }

        if containsAny(trimmed, ["纪念日", "周年", "在一起", "生日", "倒数", "考研", "高考"]) {
            let title = guessExpenseTitle(from: trimmed)
            let cat = trimmed.contains("生日") ? "生日" : (trimmed.contains("倒数") ? "倒数日" : "纪念日")
            let params = ["title": title, "category": cat]
            return PlannedAction(
                capability: .anniversaryCreate,
                params: params,
                confidence: 0.88,
                summary: Self.summary(for: .anniversaryCreate, params: params)
            )
        }
        return nil
    }

    static func extractLifeRecord(from text: String) -> PlannedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsAny(trimmed, ["猫", "狗", "宠物", "布丁", "大黄", "毛孩子"]) {
            if containsAny(trimmed, ["体外驱虫", "体内驱虫", "驱虫", "疫苗", "洗澡", "体重", "猫砂", "猫粮"]) {
                let detail: String
                if trimmed.contains("体外驱虫") { detail = "完成体外驱虫" }
                else if trimmed.contains("体内驱虫") { detail = "完成体内驱虫" }
                else if trimmed.contains("疫苗") { detail = "完成疫苗接种" }
                else if trimmed.contains("洗澡") { detail = "完成洗澡清洁" }
                else { detail = trimmed }
                let params = ["domain": "pet", "title": "宠物健康护理", "detail": detail]
                return PlannedAction(
                    capability: .lifeRecord,
                    params: params,
                    confidence: 0.88,
                    summary: Self.summary(for: .lifeRecord, params: params)
                )
            }
        }

        if containsAny(trimmed, ["车", "加油", "充电", "保养", "洗车", "年检", "里程", "油耗"]) {
            if containsAny(trimmed, ["加油", "充电", "做保养", "去保养", "做过保养", "洗了车", "年检", "里程"]) {
                let detail: String
                if trimmed.contains("加油") { detail = "完成燃油补能" }
                else if trimmed.contains("充电") { detail = "完成电动补能" }
                else if trimmed.contains("保养") { detail = "完成常规保养" }
                else if trimmed.contains("洗车") { detail = "完成车辆清洗" }
                else { detail = trimmed }
                let params = ["domain": "vehicle", "title": "爱车养护补能", "detail": detail]
                return PlannedAction(
                    capability: .lifeRecord,
                    params: params,
                    confidence: 0.88,
                    summary: Self.summary(for: .lifeRecord, params: params)
                )
            }
        }

        if containsAny(trimmed, ["宝宝", "孩子", "儿子", "女儿", "婴儿", "幼童"]) {
            if containsAny(trimmed, ["身高", "体重", "头围", "长高", "会翻身", "会独坐", "会走路", "长牙", "叫爸爸", "叫妈妈"]) {
                let params = ["domain": "child", "title": "亲子成长记录", "detail": trimmed]
                return PlannedAction(
                    capability: .lifeRecord,
                    params: params,
                    confidence: 0.88,
                    summary: Self.summary(for: .lifeRecord, params: params)
                )
            }
        }

        if containsAny(trimmed, ["练琴", "练吉他", "练习", "练字", "背单词", "口语练习", "技能学习"]) {
            let params = ["domain": "skill", "title": "技能练习打卡", "detail": trimmed]
            return PlannedAction(
                capability: .lifeRecord,
                params: params,
                confidence: 0.85,
                summary: Self.summary(for: .lifeRecord, params: params)
            )
        }

        if containsAny(trimmed, ["登记身份证", "登记护照", "驾驶证号", "行驶证号"]) {
            let params = ["domain": "document", "title": "重要证件登记", "detail": trimmed]
            return PlannedAction(
                capability: .lifeRecord,
                params: params,
                confidence: 0.85,
                summary: Self.summary(for: .lifeRecord, params: params)
            )
        }
        if containsAny(trimmed, ["筹备婚礼", "装修新房", "新房装修", "搬家乔迁"]) {
            let params = ["domain": "event", "title": "人生大事筹备", "detail": trimmed]
            return PlannedAction(
                capability: .lifeRecord,
                params: params,
                confidence: 0.85,
                summary: Self.summary(for: .lifeRecord, params: params)
            )
        }

        return nil
    }
}
