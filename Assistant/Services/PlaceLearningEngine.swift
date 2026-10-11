import CoreLocation
import Foundation
import SwiftData

/// 离线常驻地点自主学习与语义推断引擎
/// 学习规则（启发式时空聚类 + CLGeocoder 反向地理编码 + 端侧大模型语义推断）：
/// 1. 空间去噪聚类：相距 300 米内（或同 Wi‑Fi）的驻留点自动合并，消除室内基站/GPS 漂移产生的碎片点；
/// 2. 家（Home）判定特征：
///    - 晚间/夜间/清晨（19:00 ~ 次日 08:30）或周末全天停留占比高；
///    - 或在所有未确认地点中累计驻留次数遥遥领先且非纯工作日白天场所；
/// 3. 公司（Company）判定特征：
///    - 工作日（周一至周五）09:00 ~ 18:30 停留占比高，且深夜极少停留；
/// 4. 真实地名补全：自动通过 CLGeocoder 解析街道/商圈/小区名，彻底告别「未命名地点 1/2/3」。
@MainActor
final class PlaceLearningEngine {
    private let context: ModelContext
    private static var geocodingCache: [String: String] = [:]

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 记录一次驻留观测采样，并触发地点聚类、反向地理编码与画像更新
    public func recordObservation(
        coordinate: CLLocationCoordinate2D,
        wifiSSID: String? = nil,
        timestamp: Date = .now
    ) throws -> LearnedPlace? {
        let sample = LocationStaySample(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            wifiSSID: wifiSSID,
            timestamp: timestamp
        )
        context.insert(sample)

        // 寻找附近是否已有现存地点（300米半径阈值或相同 Wi-Fi，兼容室内定位漂移）
        let allPlaces = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let matchedPlace = allPlaces.first { place in
            if let wifi = wifiSSID, !wifi.isEmpty, place.associatedWiFiSSIDs.contains(wifi) {
                return true
            }
            let locA = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let locB = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return locA.distance(from: locB) <= max(place.radiusMeters, 300)
        }

        let targetPlace: LearnedPlace
        if let existing = matchedPlace {
            targetPlace = existing
            // 采用滑动加权平滑更新中心坐标，减小单次漂移误差
            let weight = Double(min(existing.visitCount, 20))
            targetPlace.latitude = (existing.latitude * weight + coordinate.latitude) / (weight + 1.0)
            targetPlace.longitude = (existing.longitude * weight + coordinate.longitude) / (weight + 1.0)
            targetPlace.visitCount += 1
            targetPlace.lastVisitedAt = timestamp
            if let wifi = wifiSSID, !wifi.isEmpty, !targetPlace.associatedWiFiSSIDs.contains(wifi) {
                targetPlace.associatedWiFiSSIDs.append(wifi)
            }
        } else {
            let newPlace = LearnedPlace(
                name: "定位解析中…",
                category: .other,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: 200,
                associatedWiFiSSIDs: wifiSSID.map { [$0] } ?? []
            )
            context.insert(newPlace)
            targetPlace = newPlace
        }

        // 重新分析所有未锁定地点的常驻模式
        try reanalyzeAllPlaces()
        try context.save()

        // 异步解析真实街道/POI 名称并触发端侧语义命名
        Task { @MainActor in
            await enrichPlaceNameIfNeeded(targetPlace)
        }

        return targetPlace
    }

    /// 合并漂移碎片地点、重算全部未锁定地点的「家/公司/驿站」角色，并补全真实地名
    public func refreshAndDeduplicateAllPlaces(useAI: Bool = false) async {
        do {
            try mergeNearbyDriftedPlaces()
            try reanalyzeAllPlaces()
            try context.save()
        } catch {
            // 忽略单次保存异常
        }

        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        ))) ?? []

        for place in places {
            await enrichPlaceNameIfNeeded(place, forceAI: useAI)
        }
        try? context.save()
    }

    /// 合并距离过近（<= 300m）或同 Wi‑Fi 的未手动确认碎片地点
    private func mergeNearbyDriftedPlaces() throws {
        let allPlaces = try context.fetch(FetchDescriptor<LearnedPlace>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        ))
        guard allPlaces.count > 1 else { return }

        var keptPlaces: [LearnedPlace] = []
        for candidate in allPlaces {
            if candidate.isUserConfirmed {
                keptPlaces.append(candidate)
                continue
            }

            let candidateLoc = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
            if let primary = keptPlaces.first(where: { existing in
                if !existing.associatedWiFiSSIDs.isEmpty,
                   !Set(existing.associatedWiFiSSIDs).isDisjoint(with: Set(candidate.associatedWiFiSSIDs)) {
                    return true
                }
                let existingLoc = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
                return existingLoc.distance(from: candidateLoc) <= 300
            }) {
                // 将碎片点合并至主地点
                let totalVisits = max(1, primary.visitCount + candidate.visitCount)
                primary.latitude = (primary.latitude * Double(primary.visitCount) + candidate.latitude * Double(candidate.visitCount)) / Double(totalVisits)
                primary.longitude = (primary.longitude * Double(primary.visitCount) + candidate.longitude * Double(candidate.visitCount)) / Double(totalVisits)
                primary.visitCount = totalVisits
                if candidate.lastVisitedAt > primary.lastVisitedAt {
                    primary.lastVisitedAt = candidate.lastVisitedAt
                }
                for ssid in candidate.associatedWiFiSSIDs where !primary.associatedWiFiSSIDs.contains(ssid) {
                    primary.associatedWiFiSSIDs.append(ssid)
                }
                context.delete(candidate)
            } else {
                keptPlaces.append(candidate)
            }
        }
    }

    /// 依据历史采样与相对访问频次综合推断所有地点的角色（家 / 公司 / 驿站 / 常去点）
    public func reanalyzeAllPlaces() throws {
        let allPlaces = try context.fetch(FetchDescriptor<LearnedPlace>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        ))
        let allSamples = (try? context.fetch(FetchDescriptor<LocationStaySample>())) ?? []

        // 统计最高访问量地点，辅助判断常驻主地点
        let maxVisitCount = allPlaces.map(\.visitCount).max() ?? 1

        for place in allPlaces {
            let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let nearbySamples = allSamples.filter { sample in
                let sLoc = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
                return loc.distance(from: sLoc) <= 300
            }

            if !nearbySamples.isEmpty {
                var homeWeightedScore = 0.0
                var workdayDayCount = 0
                let total = Double(nearbySamples.count)

                for s in nearbySamples {
                    // 家庭休息时段：深夜/清晨 (22:00~08:00)、工作日傍晚 (19:00~22:00) 或周末全天
                    if s.hourOfDay >= 22 || s.hourOfDay <= 8 {
                        homeWeightedScore += 1.0
                    } else if s.hourOfDay >= 19 {
                        homeWeightedScore += 0.85
                    } else if s.isWeekend {
                        homeWeightedScore += 0.80
                    }

                    // 工作日白天办公时段 (周一至周五 09:00 ~ 18:00)
                    if !s.isWeekend && (s.hourOfDay >= 9 && s.hourOfDay <= 18) {
                        workdayDayCount += 1
                    }
                }

                let homeProb = min(1.0, homeWeightedScore / total)
                let workdayProb = Double(workdayDayCount) / total
                place.nightStayProbability = homeProb
                place.workdayDayStayProbability = workdayProb
            }

            guard !place.isUserConfirmed else { continue }

            let homeProb = place.nightStayProbability
            let workdayProb = place.workdayDayStayProbability

            // 规则 1：居家特征显著，或是用户压倒性高频驻留点（例如停留 >= 10 次且占比最高，且非纯工作日白天点）
            let isDominantStay = place.visitCount >= 8 && place.visitCount == maxVisitCount && workdayProb < 0.65
            if homeProb >= 0.40 || isDominantStay {
                place.category = .home
                if place.nightStayProbability < 0.40 {
                    place.nightStayProbability = max(place.nightStayProbability, 0.72)
                }
                if Self.isPlaceholderName(place.name) {
                    place.name = "家"
                }
            } else if workdayProb >= 0.45 && place.visitCount >= 3 {
                place.category = .company
                if Self.isPlaceholderName(place.name) {
                    place.name = "公司"
                }
            }
        }
    }

    /// 判断名称是否仍为未命名占位符
    public static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ||
            trimmed.hasPrefix("未命名") ||
            trimmed.hasPrefix("定位解析中") ||
            trimmed == "其他地点"
    }

    /// 使用 CLGeocoder 反向地理编码 + 端侧大模型为地点生成有意义的真实名称与角色
    public func enrichPlaceNameIfNeeded(_ place: LearnedPlace, forceAI: Bool = false) async {
        guard place.latitude != 0 || place.longitude != 0 else { return }

        let coordKey = String(format: "%.3f,%.3f", place.latitude, place.longitude)
        var resolvedGeoLabel = Self.geocodingCache[coordKey]

        if resolvedGeoLabel == nil {
            let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                resolvedGeoLabel = Self.formatPlacemark(placemark)
                if let resolvedGeoLabel, !resolvedGeoLabel.isEmpty {
                    Self.geocodingCache[coordKey] = resolvedGeoLabel
                }
            }
        }

        // 若该地址文本包含驿站/丰巢/快递柜关键词，且尚未被用户锁定
        if !place.isUserConfirmed,
           let geo = resolvedGeoLabel,
           (geo.contains("驿站") || geo.contains("丰巢") || geo.contains("快递")) {
            place.category = .parcelStation
        }

        // 根据类别与反向地理编码更新名称，彻底消除“未命名地点 X”
        if let geo = resolvedGeoLabel, !geo.isEmpty {
            if Self.isPlaceholderName(place.name) {
                switch place.category {
                case .home:
                    place.name = "家（\(geo)）"
                case .company:
                    place.name = "公司（\(geo)）"
                case .parcelStation:
                    place.name = "常用驿站（\(geo)）"
                case .other:
                    place.name = geo
                }
            } else if (place.name == "家" || place.name == "公司" || place.name == "常用驿站"),
                      !place.name.contains("（") {
                place.name = "\(place.name)（\(geo)）"
            }
        } else if Self.isPlaceholderName(place.name) {
            switch place.category {
            case .home:
                place.name = "家"
            case .company:
                place.name = "公司"
            case .parcelStation:
                place.name = "常用驿站"
            case .other:
                place.name = String(format: "常去地点 (%.3f, %.3f)", place.latitude, place.longitude)
            }
        }

        // 若开启了端侧 AI 深度推断（且用户未手动锁定），结合停留频次、时段与周边地名推断角色
        if forceAI && !place.isUserConfirmed {
            let geoDesc = resolvedGeoLabel ?? place.name
            let wifiDesc = place.associatedWiFiSSIDs.isEmpty ? "无" : place.associatedWiFiSSIDs.joined(separator: ",")
            let sys = """
            你是地点语义角色推断助手。请根据用户在该地点的驻留统计与周边地名，判断该地点属于「家」、「公司」、「常用驿站」还是「其他地点」，并给出一个简短易读的名称（10字以内）。
            严格按以下格式输出一行（不要解释）：
            分类｜地点名称
            """
            let userPrompt = "地名：\(geoDesc)；累计停留：\(place.visitCount)次；居家/晚间周末概率：\(Int(place.nightStayProbability * 100))%；工作日白天概率：\(Int(place.workdayDayStayProbability * 100))%；关联Wi-Fi：\(wifiDesc)"
            if let aiReply = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: userPrompt,
                maxNewTokens: 40
            ) {
                let firstLine = aiReply.components(separatedBy: .newlines).first ?? aiReply
                let parts = firstLine.components(separatedBy: CharacterSet(charactersIn: "｜|:："))
                if parts.count >= 2 {
                    let catStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let nameStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if catStr.contains("家") {
                        place.category = .home
                    } else if catStr.contains("公司") || catStr.contains("办公") {
                        place.category = .company
                    } else if catStr.contains("驿站") || catStr.contains("快递") {
                        place.category = .parcelStation
                    }
                    if !nameStr.isEmpty && nameStr.count <= 18 && !Self.isPlaceholderName(nameStr) {
                        place.name = nameStr
                    }
                }
            }
        }

        try? context.save()
    }

    /// 提取精炼的「区 + 街道/商圈/POI」可读地名
    private static func formatPlacemark(_ placemark: CLPlacemark) -> String {
        let district = placemark.subLocality ?? placemark.locality ?? ""
        let poi = placemark.areasOfInterest?.first ?? ""
        let street = placemark.thoroughfare ?? ""
        let rawName = placemark.name ?? ""

        if !poi.isEmpty {
            return district.isEmpty || poi.hasPrefix(district) ? poi : "\(district)·\(poi)"
        }

        // 若 placemark.name 是具体建筑物/小区名（且不是纯门牌或长串省市区）
        if !rawName.isEmpty,
           rawName != district,
           rawName != placemark.locality,
           rawName.count <= 14 {
            let cleanedName = rawName
                .replacingOccurrences(of: placemark.administrativeArea ?? "", with: "")
                .replacingOccurrences(of: placemark.locality ?? "", with: "")
            if !cleanedName.isEmpty {
                return cleanedName
            }
        }

        if !street.isEmpty {
            return district.isEmpty ? street : "\(district)·\(street)"
        }

        if !district.isEmpty {
            return district
        }

        return rawName
    }

    /// 根据 Wi-Fi 或坐标判断当前处于哪里
    public func resolveCurrentPlace(
        wifiSSID: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil
    ) -> LearnedPlace? {
        let allPlaces = (try? context.fetch(FetchDescriptor<LearnedPlace>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        ))) ?? []

        // 1. 优先使用 Wi-Fi 快速匹配
        if let wifi = wifiSSID, !wifi.isEmpty {
            if let hit = allPlaces.first(where: { $0.associatedWiFiSSIDs.contains(wifi) }) {
                return hit
            }
        }

        // 2. 使用地理坐标匹配
        if let coord = coordinate {
            let targetLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            return allPlaces.first { place in
                let pLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                return pLoc.distance(from: targetLoc) <= max(place.radiusMeters, 250)
            }
        }

        return nil
    }
}
