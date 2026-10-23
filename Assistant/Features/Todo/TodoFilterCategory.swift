import Foundation

enum TodoFilterCategory: String, CaseIterable, Identifiable, Hashable {
    case all = "全部"
    case general = "今日待办"
    case work = "工作"
    case recurring = "周期"
    case parcel = "快递"
    case life = "生活"
    case alert = "预警"
    case parenting = "育儿"
    case pet = "宠物"
    case other = "其它"

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "全部": self = .all
        case "今日待办", "待办": self = .general
        case "工作": self = .work
        case "周期": self = .recurring
        case "快递": self = .parcel
        case "生活": self = .life
        case "预警": self = .alert
        case "育儿": self = .parenting
        case "宠物": self = .pet
        case "其它": self = .other
        default: return nil
        }
    }
}

enum TodoCategoryPreferences {
    private static let key = "todo_home_category_order_v1"
    private static let workCategoryMigratedKey = "todo_home_category_work_migrated_v1"
    private static let otherCategoryMigratedKey = "todo_home_category_other_migrated_v1"

    static func load() -> [TodoFilterCategory] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return TodoFilterCategory.allCases
        }
        var categories = rawValues.compactMap { raw -> TodoFilterCategory? in
            if raw == "待办" { return .general }
            return TodoFilterCategory(rawValue: raw)
        }.uniqued()
        if !categories.contains(.all) { categories.insert(.all, at: 0) }
        if !categories.contains(.general) {
            categories.insert(.general, at: min(1, categories.count))
        }
        // 一次性迁移：旧存档顺序自动补入新增的“工作”类目；此后用户再手动移除则尊重其选择
        if !UserDefaults.standard.bool(forKey: workCategoryMigratedKey) {
            if !categories.contains(.work), let idx = categories.firstIndex(of: .general) {
                categories.insert(.work, at: idx + 1)
            }
            UserDefaults.standard.set(true, forKey: workCategoryMigratedKey)
        }
        // 一次性迁移：旧存档顺序自动补入新增的“其它”类目
        if !UserDefaults.standard.bool(forKey: otherCategoryMigratedKey) {
            if !categories.contains(.other) {
                categories.append(.other)
            }
            UserDefaults.standard.set(true, forKey: otherCategoryMigratedKey)
        }
        return categories
    }

    static func save(_ categories: [TodoFilterCategory]) {
        let rawValues = categories.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawValues) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
