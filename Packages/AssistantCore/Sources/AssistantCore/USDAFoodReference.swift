import Foundation

/// 随 App 打包的 FoodData Central 资料。JSON 保留原始 fdc_id、英文名和营养字段；
/// 只有经过核对的条目才会通过 FoodCatalog 的映射参与自动估算。
enum USDAFoodReference {
    struct Entry: Decodable {
        let id: String
        let name: String
        let nameEn: String
        let fdcID: FDCID
        let dataType: String
        let servingGrams: Double
        let per100g: Nutrients

        enum CodingKeys: String, CodingKey {
            case id, name, fdcID = "fdc_id", dataType = "data_type"
            case nameEn = "name_en", servingGrams = "serving_g", per100g
        }
    }

    struct Nutrients: Decodable {
        let kcal: Double
    }

    struct FDCID: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let id = try? container.decode(String.self) {
                value = id
            } else {
                value = String(try container.decode(Int.self))
            }
        }
    }

    private struct File: Decodable {
        let foods: [Entry]
    }

    static let entriesByID: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "foods", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            assertionFailure("无法读取随 App 打包的 USDA 食物资料")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: file.foods.map { ($0.id, $0) })
    }()
}
