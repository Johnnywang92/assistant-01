import Foundation
import SwiftUI

/// 离线群体常模共鸣结构体
public struct CohortResonanceInsight: Identifiable, Sendable {
    public var id = UUID()
    public var cohortStatistic: String       // 群体基准统计，如 "👥 68.4% 的人在周一存在精力启动延迟"
    public var statTag: String               // 标签，如 "周一启动期"
    public var sampleContext: String         // 样本基准说明，如 "基于国民身心节律常模统计"
    public var companionEcho: String         // 所选搭子人格的具体评语/回响
    public var echoPersona: CompanionPersonaType
}

/// 离线群体常模参考系与拟真回响计算引擎
public enum CohortResonanceEngine {

    /// 核心推断函数：根据当日情绪、收支、待办和时间维度评估群体共鸣
    public static func evaluate(
        moodScore: Int?,
        energyScore: Int?,
        stressScore: Int?,
        completedTodosCount: Int = 0,
        pendingTodosCount: Int = 0,
        todayExpenseAmount: Double = 0,
        persona: CompanionPersonaType = .warmRoommate,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CohortResonanceInsight {
        let weekday = calendar.component(.weekday, from: now) // 1=Sunday, 2=Monday, 7=Saturday
        let hour = calendar.component(.hour, from: now)
        let isMonday = (weekday == 2)
        let isFriday = (weekday == 6)
        let isLateNight = (hour >= 22 || hour < 5)

        let mood = moodScore ?? 3
        let energy = energyScore ?? 3
        let stress = stressScore ?? 2

        // 1. 周一早起低精力 / 启动阻力场景
        if isMonday && (energy <= 2 || mood <= 2) {
            return CohortResonanceInsight(
                cohortStatistic: "68.4% 的职场人群在周一上午存在「精力启动延迟」，这不是自律缺失，而是神经节律切换的自然生理保护。",
                statTag: "周一启动缓冲",
                sampleContext: "国民工作日心理能量波动常模",
                companionEcho: mondayMorningEcho(persona: persona, pendingCount: pendingTodosCount),
                echoPersona: persona
            )
        }

        // 2. 深夜高压或思绪万千
        if isLateNight && stress >= 3 {
            return CohortResonanceInsight(
                cohortStatistic: "夜间 22 点后，超过 55.2% 的人会在闭眼前短暂放大未尽事宜的心理焦虑。你感知到的压力属于集体夜间节律放大效应。",
                statTag: "深夜情绪消化",
                sampleContext: "城市青年夜间心理负荷基准",
                companionEcho: lateNightStressEcho(persona: persona),
                echoPersona: persona
            )
        }

        // 3. 高压高负荷（压力 >= 4）
        if stress >= 4 {
            return CohortResonanceInsight(
                cohortStatistic: "在快节奏生活周期中，当前时段有 43.7% 的同龄人同样处于承压峰值。「允许自己偶尔低效」是保持长久韧性的关键能力。",
                statTag: "高压同行",
                sampleContext: "现代职场人生活压力分布常模",
                companionEcho: highStressEcho(persona: persona),
                echoPersona: persona
            )
        }

        // 4. 精力低谷疲劳（精力 <= 2）
        if energy <= 2 {
            return CohortResonanceInsight(
                cohortStatistic: "生理节律研究显示，人在连续高强度运转 3 天后，精力自发回落 40% 是身体的强制散热保护，不必为此感到负罪。",
                statTag: "生理强制散热",
                sampleContext: "自主神经平衡与体力恢复常模",
                companionEcho: lowEnergyEcho(persona: persona),
                echoPersona: persona
            )
        }

        // 5. 情绪与精力双高（心情 >= 4 且精力 >= 4）
        if mood >= 4 && energy >= 4 {
            return CohortResonanceInsight(
                cohortStatistic: "太棒了！你今天的心理愉悦感与神经激活度位于同龄基准前 16% 的高位期，是攻克关键事项的最佳时刻。",
                statTag: "心流高光期",
                sampleContext: "国民心流与幸福感分布基准",
                companionEcho: highVibeEcho(persona: persona, pendingCount: pendingTodosCount),
                echoPersona: persona
            )
        }

        // 6. 周五下班前夕
        if isFriday && hour >= 16 {
            return CohortResonanceInsight(
                cohortStatistic: "周五傍晚 16 点后，人群心理愉悦均值比周中高出 31.8%，多巴胺提前释放，整个城市都在期待周末的落日。",
                statTag: "周末前夕共振",
                sampleContext: "一周情绪周期动力学统计",
                companionEcho: fridayEcho(persona: persona),
                echoPersona: persona
            )
        }

        // 7. 消费记账相关宽慰
        if todayExpenseAmount > 150 {
            return CohortResonanceInsight(
                cohortStatistic: "全国都市生活手账基准显示，82.5% 的年轻人每周会有 1~2 次为满足感买单的犒赏性消费。在安心花额度内的支出是生活的调味剂。",
                statTag: "理性犒赏",
                sampleContext: "青年生活预算与满意度调研",
                companionEcho: expenseComfortEcho(persona: persona, amount: todayExpenseAmount),
                echoPersona: persona
            )
        }

        // 8. 默认平稳常态（日常力量）
        return CohortResonanceInsight(
            cohortStatistic: "平淡是生活的底色：超过 62% 的高心理韧性人群，正是依靠一个个看似普通却有秩序的日常积蓄出前进的力量。",
            statTag: "日常秩序感",
            sampleContext: "日常生活满意度基线模型",
            companionEcho: defaultDayEcho(persona: persona, completedCount: completedTodosCount),
            echoPersona: persona
        )
    }

    // MARK: - 拟真搭子台词库（多套变体防审美疲劳）

    private static func mondayMorningEcho(persona: CompanionPersonaType, pendingCount: Int) -> String {
        switch persona {
        case .warmRoommate:
            return "周一嘛，大脑齿轮转得慢太正常了！桌上给你放了热水，今天别把自己逼太紧，先挑最简单的那件事做，其他的咱们慢慢来。"
        case .wittyMentor:
            return "哟，看你这精气神，周一综合征如约而至了？听哥的，先别盯着那堆待办发愁，去洗把脸泡杯浓茶，先把第一件搞定，剩下的兵来将挡！"
        case .zenMaster:
            return "周一始发，万物有常。水流遇石则缓，风过林木有声。接纳此刻的迟滞，心安顿下来，事自会井然。"
        }
    }

    private static func lateNightStressEcho(persona: CompanionPersonaType) -> String {
        switch persona {
        case .warmRoommate:
            return "夜深啦，别把今天的烦心事带上床。屋里的灯我都替你调暗了，闭上眼睛深呼吸三次，天大的事明天睡醒再说，今晚你只负责做个好梦。"
        case .wittyMentor:
            return "都几点了还在跟脑子里的念头打架？手机赶紧放下，今天的事今天结，没办完的留给明天的你去收拾，现在立刻、马上合上眼皮！"
        case .zenMaster:
            return "夜幕垂落，当知止息。万事翻覆如浮云，唯当下一枕安眠。放下思虑，息心安枕。"
        }
    }

    private static func highStressEcho(persona: CompanionPersonaType) -> String {
        switch persona {
        case .warmRoommate:
            return "抱抱你！我知道你最近扛着很多事情，觉得累就靠在椅背上闭目养神五分钟。不用证明给谁看，你的付出我都看在眼里。"
        case .wittyMentor:
            return "压力大说明你正在走上坡路，但可别把自己当铁人造！任务拆细点，干完一件划掉一件，有我在这儿盯着你，慌什么！"
        case .zenMaster:
            return "山高自有客行路，水深自有渡船人。重压当前，不妨退一步观照，非汝不力，乃境遇使然。缓缓行，莫慌张。"
        }
    }

    private static func lowEnergyEcho(persona: CompanionPersonaType) -> String {
        switch persona {
        case .warmRoommate:
            return "电量见底了对不对？那就允许自己停一停，喝点热汤或者出去吹吹风。生活不是短跑，充饱电再出发一点也不晚。"
        case .wittyMentor:
            return "机器连轴转还得加机油呢，赶紧离屏幕远点！去阳台伸个懒腰，喝口水，休整 15 分钟再战，别硬撑着瞎耗电！"
        case .zenMaster:
            return "张弛有道，枯荣随季。精力不足即是身体的呼唤，顺从自然，稍作静卧，气血自能徐徐归位。"
        }
    }

    private static func highVibeEcho(persona: CompanionPersonaType, pendingCount: Int) -> String {
        switch persona {
        case .warmRoommate:
            return "哇，今天状态神勇！看到你元气满满我也跟着开心！趁着这股好劲头冲一波，晚上咱们好好犒劳一下自己！"
        case .wittyMentor:
            return "不错嘛！今天状态直接拉满了！趁现在思维最敏捷，赶紧把平时拖延的大骨头啃掉，别把好状态浪费在划水上！"
        case .zenMaster:
            return "意气风发，当顺势而为。心无滞碍，手落自成。乘此朗照之心，行合道之事。"
        }
    }

    private static func fridayEcho(persona: CompanionPersonaType) -> String {
        switch persona {
        case .warmRoommate:
            return "周五的快乐终于到啦！这一整周你都辛苦了，今晚什么都别想，好好享受属于自己的周末时光！"
        case .wittyMentor:
            return "熬到周五算你通关！手头剩下的活速战速决，别把尾巴拖进周末，晚上吃顿好的犒劳下本周英勇的自己！"
        case .zenMaster:
            return "一周劳作终有时，暮色将至待休歇。收拢散逸之念，静享周末闲暇。"
        }
    }

    private static func expenseComfortEcho(persona: CompanionPersonaType, amount: Double) -> String {
        let amtStr = String(format: "%.1f", amount)
        switch persona {
        case .warmRoommate:
            return "今天花了 ¥\(amtStr)，但只要买到了开心和满足就很值呀！钱花出去了是流动的生活品质，别有心理负担～"
        case .wittyMentor:
            return "今天这 ¥\(amtStr) 花得挺豪爽啊？记在账上明明白白就行，只要在预算红线内就大胆享受，下半周把零碎开销控一控就扯平了！"
        case .zenMaster:
            return "金钱不过流转之物，所换者若为身心安顿，即无虚掷。知止善用，心不随物役便好。"
        }
    }

    private static func defaultDayEcho(persona: CompanionPersonaType, completedCount: Int) -> String {
        switch persona {
        case .warmRoommate:
            if completedCount > 0 {
                return "今天已经踏踏实实完成了 \(completedCount) 项事情呢！一步一个脚印，为你鼓掌！"
            }
            return "今天也是认真生活的一天。哪怕只是按时吃饭、喝足水，也是对自己了不起的照顾。"
        case .wittyMentor:
            if completedCount > 0 {
                return "不错，今天干掉了 \(completedCount) 个任务，保持这个节奏，看谁还能说你拖延！"
            }
            return "日子一天天地过，把日常该办的办好，平凡人的踏实最千金难买，继续稳住！"
        case .zenMaster:
            return "日日是好日，事事在心间。无论行得快慢，安住当下，便无虚度。"
        }
    }
}
