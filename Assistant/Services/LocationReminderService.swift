import CoreLocation
import Foundation
import SwiftData
import UserNotifications

/// 地理围栏与定位提醒服务（完全基于 CoreLocation 硬件事件触发，离线运作）
public final class LocationReminderService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationReminderService()

    private let locationManager = CLLocationManager()
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }

    /// 请求始终允许定位（地理围栏后台触发所必须）
    public func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    /// 为指定地点（如驿站/家/公司）注册地理围栏监听
    /// - Parameters:
    ///   - coordinate: 经纬度
    ///   - radius: 半径（米），默认 150 米
    ///   - identifier: 围栏唯一标示（例如 Station-Name）
    ///   - notifyOnEntry: 到达时提醒
    ///   - notifyOnExit: 离开时提醒
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

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
        }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // 用户到达驿站或指定地点附近
        Task { @MainActor in
            let context = Persistence.shared.mainContext
            let active = TodoStatus.active.rawValue
            let parcel = TodoType.parcel.rawValue

            let descriptor = FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.typeRaw == parcel && $0.statusRaw == active }
            )
            guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }

            let codes = items.compactMap(\.pickupCode).joined(separator: "、")
            let title = "📦 你已到达驿站附近"
            let body = "你有 \(items.count) 个待取快递：取件码 \(codes)"

            NotificationService.post(title: title, body: body, id: "geofence-\(region.identifier)")
        }
    }
}
