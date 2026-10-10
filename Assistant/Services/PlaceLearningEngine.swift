import CoreLocation
import Foundation
import SwiftData

/// 离线常驻地点自主学习引擎
/// 学习规则（启发式聚类 + 时段行为统计）：
/// 1. 空间聚类：相距 200 米内的驻留点自动合并为一个候选地点；
/// 2. 家（Home）判定特征：
///    - 晚上 22:00 ~ 早上 07:00 驻留频率最高；
///    - 周末全天停留概率高；
///    - 绑定的 Wi-Fi 在夜间持续连接。
/// 3. 公司（Company）判定特征：
///    - 工作日（周一至周五）09:00 ~ 18:00 停留频率最高；
///    - 周末极少停留。
/// 4. 驿站（Station）判定特征：
///    - 快递短信中出现的地点文本，与当前停留坐标匹配，或短时间高频进出。
@MainActor
final class PlaceLearningEngine {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 记录一次驻留观测采样，并触发地点聚类与画像更新
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

        // 寻找附近是否已有现存地点（200米半径阈值）
        let allPlaces = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let matchedPlace = allPlaces.first { place in
            let locA = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let locB = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return locA.distance(from: locB) <= 200
        }

        let targetPlace: LearnedPlace
        if let existing = matchedPlace {
            targetPlace = existing
            targetPlace.visitCount += 1
            targetPlace.lastVisitedAt = timestamp
            if let wifi = wifiSSID, !wifi.isEmpty, !targetPlace.associatedWiFiSSIDs.contains(wifi) {
                targetPlace.associatedWiFiSSIDs.append(wifi)
            }
        } else {
            // 新发现地点，初始分类为其他地点
            let newPlace = LearnedPlace(
                name: "未命名地点 \(allPlaces.count + 1)",
                category: .other,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: 150,
                associatedWiFiSSIDs: wifiSSID.map { [$0] } ?? []
            )
            context.insert(newPlace)
            targetPlace = newPlace
        }

        // 重新分析该地点的常驻模式（若用户未手动锁定分类）
        if !targetPlace.isUserConfirmed {
            try reanalyzeCategory(for: targetPlace)
        }

        try context.save()
        return targetPlace
    }

    /// 依据历史采样聚类分析地点角色
    private func reanalyzeCategory(for place: LearnedPlace) throws {
        let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)

        // 取出该地点 200 米内的所有历史采样
        let allSamples = try context.fetch(FetchDescriptor<LocationStaySample>())
        let nearbySamples = allSamples.filter { sample in
            let sLoc = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
            return loc.distance(from: sLoc) <= 200
        }

        guard nearbySamples.count >= 3 else {
            // 样本数过少，保持原样
            return
        }

        var nightCount = 0
        var workdayDayCount = 0
        let total = Double(nearbySamples.count)

        for s in nearbySamples {
            // 夜间时段 (22:00 ~ 07:00)
            if s.hourOfDay >= 22 || s.hourOfDay <= 7 {
                nightCount += 1
            }
            // 工作日白天 (周一至周五 09:00 ~ 18:00)
            if !s.isWeekend && (s.hourOfDay >= 9 && s.hourOfDay <= 18) {
                workdayDayCount += 1
            }
        }

        let nightProb = Double(nightCount) / total
        let workdayDayProb = Double(workdayDayCount) / total

        place.nightStayProbability = nightProb
        place.workdayDayStayProbability = workdayDayProb

        // 判定规则：
        if nightProb >= 0.4 {
            place.category = .home
            if place.name.hasPrefix("未命名") {
                place.name = "家"
            }
        } else if workdayDayProb >= 0.45 {
            place.category = .company
            if place.name.hasPrefix("未命名") {
                place.name = "公司"
            }
        }
    }

    /// 根据 Wi-Fi 或坐标判断当前处于哪里
    public func resolveCurrentPlace(
        wifiSSID: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil
    ) -> LearnedPlace? {
        let allPlaces = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []

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
                return pLoc.distance(from: targetLoc) <= place.radiusMeters
            }
        }

        return nil
    }
}
