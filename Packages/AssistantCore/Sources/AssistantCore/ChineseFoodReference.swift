import Foundation

/// 用户提供的中式菜谱、面食和点心资料。
/// 菜品采用「标准」油量档，面食和点心采用资料中的每 100g 热量。
enum ChineseFoodReference {
    struct Entry: Decodable {
        let id: String
        let name: String
        let aliases: [String]
        let nameEn: String
        let category: String
        let servingGrams: Double
        let kcalPer100g: Double
        let source: String

        enum CodingKeys: String, CodingKey {
            case id, name, aliases, nameEn = "name_en", category
            case servingGrams = "serving_g", kcalPer100g = "kcal", source
        }
    }

    private struct File: Decodable { let foods: [Entry] }

    static let entries: [Entry] = {
        guard let url = Bundle.module.url(forResource: "chinese_foods", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            assertionFailure("无法读取随 App 打包的中式食物资料")
            return []
        }
        return file.foods.filter {
            $0.servingGrams > 0 && $0.kcalPer100g.isFinite && $0.kcalPer100g >= 0
        }
    }()
}
