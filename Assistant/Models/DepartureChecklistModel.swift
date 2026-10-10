import Foundation
import SwiftData

/// 出门与随身出行场景
public enum DepartureScene: String, Codable, CaseIterable, Identifiable {
    case commute = "工作通勤"
    case workout = "运动健身"
    case travel = "出差旅行"
    case parenting = "带娃出行"
    case petWalk = "遛狗随行"
    case rainy = "雨雪恶劣"
    case casual = "日常轻装"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .commute: return "briefcase.fill"
        case .workout: return "figure.run"
        case .travel: return "airplane"
        case .parenting: return "figure.and.child.holdinghands"
        case .petWalk: return "pawprint.fill"
        case .rainy: return "cloud.rain.fill"
        case .casual: return "bag.fill"
        }
    }

    public var colorName: String {
        switch self {
        case .commute: return "blue"
        case .workout: return "orange"
        case .travel: return "purple"
        case .parenting: return "pink"
        case .petWalk: return "teal"
        case .rainy: return "teal"
        case .casual: return "green"
        }
    }
}

/// 随身防丢与出门检查清单项模型
@Model
public final class DepartureCheckItem {
    public var id: UUID
    public var title: String                // 物品名称（如：电脑电源、工卡、耳机、家门钥匙）
    public var sceneRaw: String             // 归属场景
    public var isChecked: Bool              // 本次出发前是否已确认携带
    public var isEssential: Bool            // 是否属于核心必带项（遗漏会导致无法工作或进门）
    public var storageLocationNote: String? // 习惯放置位置，如“玄关置物盘”、“背包内侧网兜”
    public var createdAt: Date

    public init(
        title: String,
        scene: DepartureScene = .commute,
        isEssential: Bool = false,
        storageLocationNote: String? = nil,
        isChecked: Bool = false
    ) {
        self.id = UUID()
        self.title = title
        self.sceneRaw = scene.rawValue
        self.isEssential = isEssential
        self.storageLocationNote = storageLocationNote
        self.isChecked = isChecked
        self.createdAt = .now
    }

    public var scene: DepartureScene {
        get { DepartureScene(rawValue: sceneRaw) ?? .commute }
        set { sceneRaw = newValue.rawValue }
    }
}

/// 默认内置常用清单种子数据
public enum DepartureChecklistDefaults {
    public static let seeds: [(title: String, scene: DepartureScene, isEssential: Bool, location: String)] = [
        // 工作通勤
        ("家门钥匙 / 门禁卡", .commute, true, "玄关置物托盘"),
        ("公司工卡 / 工牌", .commute, true, "背包前置外袋"),
        ("笔记本电脑与电源线", .commute, true, "电脑夹层隔袋"),
        ("手机与手机壳", .commute, true, "口袋或桌面充电座"),
        ("降噪耳机 (AirPods)", .commute, false, "随身口袋"),

        // 运动健身
        ("运动水杯 / 摇摇杯", .workout, true, "厨房水槽晾干架"),
        ("运动手环 / Apple Watch", .workout, true, "床头充电座"),
        ("健身房储物柜锁", .workout, true, "运动挎包侧袋"),
        ("速干毛巾与换洗衣物", .workout, false, "衣柜运动专区"),

        // 出差旅行
        ("身份证件 / 护照", .travel, true, "随身贴身胸包"),
        ("大容量充电宝与快充线", .travel, true, "数码配件收纳包"),
        ("个人常备药品", .travel, true, "行李箱拉链内袋"),
        ("便携洗漱包与刮胡刀", .travel, false, "浴室出差洗漱袋"),

        // 带娃出行
        ("奶瓶与温水保温杯", .parenting, true, "妈妈包/随身包"),
        ("纸尿裤与婴儿柔湿巾", .parenting, true, "妈妈包"),
        ("防走失手环 / 牵引绳", .parenting, true, "玄关挂钩"),
        ("备用换洗衣物与隔尿垫", .parenting, false, "推车置物篮"),
        ("儿童防蚊喷雾 / 退热贴", .parenting, false, "妈妈包侧袋"),
        ("安抚玩具 / 儿童绘本", .parenting, false, "推车挂钩"),

        // 遛狗随行
        ("牵引绳与胸背带", .petWalk, true, "玄关入口挂钩"),
        ("拾便袋与便携收纳盒", .petWalk, true, "牵引绳挂扣"),
        ("随行便携饮水杯", .petWalk, true, "随身小包"),
        ("防丢 AirTag / 定位项圈", .petWalk, true, "宠物颈圈"),
        ("训犬奖励冻干零食", .petWalk, false, "随身口袋"),

        // 雨雪出行
        ("便携折叠雨伞", .rainy, true, "玄关伞架"),
        ("备用纸巾 / 湿巾", .rainy, false, "随身外衣口袋"),

        // 日常轻装
        ("手机", .casual, true, "随身携带"),
        ("钥匙", .casual, true, "玄关置物托盘"),
        ("纸巾", .casual, false, "口袋")
    ]
}
