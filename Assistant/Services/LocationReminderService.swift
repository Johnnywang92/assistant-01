import CoreLocation
import Foundation
import NetworkExtension
import SwiftData
import UIKit
import UserNotifications

/// 读取设备当前连接的 Wi‑Fi 名称。系统不会提供密码或附近网络列表。
@MainActor
private enum WiFiInfoService {
    static func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                let ssid = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: ssid?.isEmpty == false ? ssid : nil)
            }
        }
    }
}

/// 地理围栏与定位采样提醒服务（完全基于 CoreLocation 硬件事件触发，离线运作）
public final class LocationReminderService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationReminderService()

    private let locationManager = CLLocationManager()
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public var lastKnownLocation: CLLocation?
    @Published public var lastKnownWiFiSSID: String?
    @Published public var isSamplingLocation: Bool = false

    private let lock = NSLock()
    private var pendingLocationCompletions: [(CLLocation?) -> Void] = []

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = locationManager.authorizationStatus
    }

    /// 请求使用期间定位权限
    public func requestWhenInUseAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// 请求始终允许定位（地理围栏后台触发所必须）
    public func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    /// 读取当前连接的 Wi-Fi，供地点详情页手动关联。
    @MainActor
    public func captureCurrentWiFiSSID() async -> String? {
        let ssid = await WiFiInfoService.currentSSID()
        lastKnownWiFiSSID = ssid
        return ssid
    }

    /// 打开系统设置页（方便用户手动授予权限）
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// 请求一次单次精简定位，并自动喂给常驻地点学习引擎进行空间时空聚类
    @discardableResult
    @MainActor
    public func requestSingleLocationSample(context: ModelContext? = nil, requestPermissionIfNeeded: Bool = false) async -> CLLocationCoordinate2D? {
        let currentAuth = locationManager.authorizationStatus
        if currentAuth == .notDetermined {
            if requestPermissionIfNeeded { locationManager.requestWhenInUseAuthorization() }
            return nil
        }

        guard currentAuth == .authorizedWhenInUse || currentAuth == .authorizedAlways else {
            return nil
        }

        let currentWiFiSSID = await captureCurrentWiFiSSID()
        return await withCheckedContinuation { continuation in
            self.isSamplingLocation = true
            self.lock.lock()
            self.pendingLocationCompletions.append { [weak service = self] loc in
                guard let service else {
                    continuation.resume(returning: nil)
                    return
                }
                if let location = loc {
                    service.lastKnownLocation = location
                    service.lastKnownWiFiSSID = currentWiFiSSID
                    let ctx = context ?? Persistence.shared.mainContext
                    let engine = PlaceLearningEngine(context: ctx)
                    _ = try? engine.recordObservation(
                        coordinate: location.coordinate,
                        wifiSSID: currentWiFiSSID,
                        timestamp: .now
                    )
                    continuation.resume(returning: location.coordinate)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            self.lock.unlock()

            self.locationManager.requestLocation()
        }
    }

    /// 为指定地点（如驿站/家/公司）注册地理围栏监听
    public func startMonitoringRegion(
        center coordinate: CLLocationCoordinate2D,
        radius: CLLocationDistance = 150,
        identifier: String,
        notifyOnEntry: Bool = true,
        notifyOnExit: Bool = false
    ) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let region = CLCircularRegion(center: coordinate, radius: radius, identifier: identifier)
        region.notifyOnEntry = notifyOnEntry
        region.notifyOnExit = notifyOnExit

        locationManager.startMonitoring(for: region)
    }

    /// 停止监听指定围栏
    public func stopMonitoringRegion(identifier: String) {
        for region in locationManager.monitoredRegions {
            if region.identifier == identifier {
                locationManager.stopMonitoring(for: region)
            }
        }
    }

    /// 自动根据当前的未取快递与「常用驿站」地点档案，动态维护 CoreLocation 硬件地理围栏
    @MainActor
    public func syncParcelStationGeofences(context: ModelContext? = nil) {
        let ctx = context ?? Persistence.shared.mainContext

        // 1. 检查是否有尚未取件的活跃包裹待办
        let activeRaw = TodoStatus.active.rawValue
        let parcelRaw = TodoType.parcel.rawValue
        let returnParcelRaw = TodoType.returnParcel.rawValue

        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw && ($0.typeRaw == parcelRaw || $0.typeRaw == returnParcelRaw) }
        )
        let parcels: [TodoItem]
        do {
            parcels = try ctx.fetch(todoDescriptor)
        } catch {
            // 查询失败不等于「没有待取包裹」：按空集走会撤光驿站围栏，用户到驿站就没提醒了。
            // 这一轮直接放弃，保留现有围栏。
            print("⚠️ [LocationReminder] 包裹待办查询失败，跳过本轮围栏对账: \(error.localizedDescription)")
            return
        }
        let activeParcels = parcels.filter { !($0.pickupCode ?? "").isEmpty }

        // 2. 如果没有待取包裹，清理所有驿站相关的围栏，节省功耗与系统围栏配额
        if activeParcels.isEmpty {
            for region in locationManager.monitoredRegions {
                if region.identifier.hasPrefix("parcel-station-") {
                    locationManager.stopMonitoring(for: region)
                }
            }
            return
        }

        // 3. 有待取包裹：查找已配置的「常用驿站」或含有驿站/快递柜名称的常驻地点
        let stationRaw = PlaceCategory.parcelStation.rawValue
        let placeDescriptor = FetchDescriptor<LearnedPlace>()
        let allPlaces = (try? ctx.fetch(placeDescriptor)) ?? []
        let stations = allPlaces.filter { place in
            (place.categoryRaw == stationRaw ||
             place.name.contains("驿站") ||
             place.name.contains("菜鸟") ||
             place.name.contains("快递柜") ||
             place.name.contains("丰巢") ||
             place.name.contains("自提")) &&
            place.latitude != 0 && place.longitude != 0
        }

        guard !stations.isEmpty else {
            return
        }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let activeStationIDs = Set(stations.map { "parcel-station-\($0.id)" })

        // 清理已失效或被删除的驿站围栏
        for region in locationManager.monitoredRegions {
            if region.identifier.hasPrefix("parcel-station-") && !activeStationIDs.contains(region.identifier) {
                locationManager.stopMonitoring(for: region)
            }
        }

        // 注册现存有效的驿站围栏
        for station in stations {
            let regionId = "parcel-station-\(station.id)"
            let alreadyMonitored = locationManager.monitoredRegions.contains { $0.identifier == regionId }
            if !alreadyMonitored {
                let coord = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
                let radius = max(station.radiusMeters, 120.0) // 确保至少 120 米，保证基站与 GPS 准确命中
                startMonitoringRegion(
                    center: coord,
                    radius: radius,
                    identifier: regionId,
                    notifyOnEntry: true,
                    notifyOnExit: false
                )
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.syncParcelStationGeofences()
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        DispatchQueue.main.async {
            self.isSamplingLocation = false
            self.lock.lock()
            let callbacks = self.pendingLocationCompletions
            self.pendingLocationCompletions.removeAll()
            self.lock.unlock()

            for cb in callbacks {
                cb(loc)
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("⚠️ CoreLocation 单次定位失败: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isSamplingLocation = false
            self.lock.lock()
            let callbacks = self.pendingLocationCompletions
            self.pendingLocationCompletions.removeAll()
            self.lock.unlock()

            for cb in callbacks {
                cb(nil)
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // 用户到达驿站或指定地点附近：自动触发灵动岛、Apple Watch 智能叠放与抬腕销号
        Task { @MainActor in
            let context = Persistence.shared.mainContext
            let activeRaw = TodoStatus.active.rawValue
            let parcelRaw = TodoType.parcel.rawValue
            let returnParcelRaw = TodoType.returnParcel.rawValue

            let descriptor = FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.statusRaw == activeRaw && ($0.typeRaw == parcelRaw || $0.typeRaw == returnParcelRaw) }
            )
            let items = ((try? context.fetch(descriptor)) ?? []).filter({ !($0.pickupCode ?? "").isEmpty })
            guard !items.isEmpty else { return }

            // 1. 尝试将取件码推上灵动岛与 Apple Watch 智能叠放（iOS 16.1+ / watchOS 11+ 实时活动）
            _ = LiveActivityService.startPickupActivity(for: items)

            // 2. 匹配具体驿站名称
            let stationName: String
            if let placeIdStr = region.identifier.components(separatedBy: "parcel-station-").last,
               let placeUUID = UUID(uuidString: placeIdStr),
               let place = (try? context.fetch(FetchDescriptor<LearnedPlace>(predicate: #Predicate { $0.id == placeUUID })))?.first {
                stationName = place.name
            } else {
                stationName = items.first(where: { !($0.station ?? "").isEmpty })?.station ?? "驿站"
            }

            let codes = items.compactMap(\.pickupCode).joined(separator: "、")
            let title = "📦 已到达\(stationName)"
            let body = items.count > 1
                ? "待取快递 \(items.count) 件：\(codes)。抬腕查看取件码，取完轻点「已取件」即可销号。"
                : "取件码：\(codes)。抬腕查看取件码，取完轻点「已取件」即可销号。"

            // 3. 启动并更新手腕上的可交互伴随通知（手腕上原生支持点击「已取件 ✓」）
            PickupCheckoutService.begin(
                parcels: items.map { (id: $0.id, code: $0.pickupCode ?? "") },
                station: stationName
            )

            // 4. 发送高时效性到达声音/触感提醒，确保设备在口袋或暗屏时震动点亮屏幕
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["type": "geofence_pickup", "regionId": region.identifier]
            let req = UNNotificationRequest(
                identifier: "geofence-arrival-\(region.identifier)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }
}
