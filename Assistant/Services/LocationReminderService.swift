import CoreLocation
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// 地理围栏与定位采样提醒服务（完全基于 CoreLocation 硬件事件触发，离线运作）
public final class LocationReminderService: NSObject, ObservableObject, CLLocationManagerDelegate, @unchecked Sendable {
    public static let shared = LocationReminderService()

    private let locationManager = CLLocationManager()
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public var lastKnownLocation: CLLocation?
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

    /// 打开系统设置页（方便用户手动授予权限）
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// 请求一次单次精简定位，并自动喂给常驻地点学习引擎进行空间时空聚类
    @discardableResult
    public func requestSingleLocationSample(context: ModelContext? = nil) async -> CLLocationCoordinate2D? {
        // 若未授权，先尝试申请
        let currentAuth = locationManager.authorizationStatus
        if currentAuth == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return nil
        }

        guard currentAuth == .authorizedWhenInUse || currentAuth == .authorizedAlways else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.isSamplingLocation = true
                self.lock.lock()
                self.pendingLocationCompletions.append { [weak self] loc in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let location = loc {
                        self.lastKnownLocation = location
                        // 异步喂给地点学习引擎
                        Task { @MainActor in
                            let ctx = context ?? Persistence.shared.mainContext
                            let engine = PlaceLearningEngine(context: ctx)
                            _ = try? engine.recordObservation(coordinate: location.coordinate, timestamp: .now)
                        }
                        continuation.resume(returning: location.coordinate)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
                self.lock.unlock()

                self.locationManager.requestLocation()
            }
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

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
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
