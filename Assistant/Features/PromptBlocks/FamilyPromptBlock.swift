import AssistantCore
import Foundation
import SwiftData

/// 家庭关怀块：萌宠、宝贝育儿与爱车档案。
struct FamilyPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .family

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let pets = (try? context.fetch(FetchDescriptor<PetProfile>())) ?? []
        let children = (try? context.fetch(FetchDescriptor<ChildProfile>())) ?? []
        let vehicles = (try? context.fetch(FetchDescriptor<VehicleProfile>())) ?? []
        var familyParts: [String] = []
        if !pets.isEmpty {
            familyParts.append("宠物：" + pets.prefix(2).map { pet in
                let w = pet.weightKg.map { String(format: "%.1fkg", $0) } ?? ""
                return "\(pet.name)(\(pet.breed) \(w))"
            }.joined(separator: "、"))
        }
        if !children.isEmpty {
            familyParts.append("宝贝：" + children.prefix(2).map { child in
                let h = child.effectiveHeightCm.map { String(format: "身高%.0fcm", $0) } ?? ""
                let w = child.effectiveWeightKg.map { String(format: "体重%.1fkg", $0) } ?? ""
                return "\(child.name)(\(child.ageDescription) \(h) \(w))".trimmingCharacters(in: .whitespaces)
            }.joined(separator: "、"))
        }
        if !vehicles.isEmpty {
            familyParts.append("爱车：" + vehicles.prefix(2).map { v in
                "\(v.name)(\(v.plateNumber)，距保养\(v.daysUntilNextMaintenance)天)"
            }.joined(separator: "、"))
        }
        let familyText = familyParts.isEmpty ? "未录入" : familyParts.joined(separator: "；")
        return PromptBlock(id: id, text: "• 家庭档案(萌宠/育儿/爱车)：\(familyText)")
    }
}
