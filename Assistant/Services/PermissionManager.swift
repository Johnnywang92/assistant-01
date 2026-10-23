import AVFoundation
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import Photos
import Speech
import SwiftUI
import UIKit
import UserNotifications

/// 全局权限管理与健康度检测中心（集中检查与集中赋予所有系统权限）
@MainActor
public final class PermissionManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = PermissionManager()

    public enum PermissionState: Equatable, Sendable {
        case authorized
        case denied
        case notDetermined
        case limited

        public var isReady: Bool {
            self == .authorized || self == .limited
        }
    }

    // MARK: - 全量系统权限状态

    /// 1. 系统通知
    @Published public var notificationStatus: PermissionState = .notDetermined
    /// 2. 地理定位
    @Published public var locationStatus: PermissionState = .notDetermined
    /// 3. 麦克风
    @Published public var microphoneStatus: PermissionState = .notDetermined
    /// 4. 语音识别
    @Published public var speechStatus: PermissionState = .notDetermined
    /// 5. 相册照片
    @Published public var photoStatus: PermissionState = .notDetermined
    /// 6. 相机拍摄
    @Published public var cameraStatus: PermissionState = .notDetermined
    /// 7. 系统日历
    @Published public var calendarStatus: PermissionState = .notDetermined
    /// 8. 运动与健身
    @Published public var motionStatus: PermissionState = .notDetermined
    /// 9. Apple 健康（HealthKit）
    @Published public var healthStatus: PermissionState = .notDetermined

    /// 是否已展示/完成初次权限引导
    @AppStorage("has_completed_permission_onboarding_v1") public var hasCompletedOnboarding: Bool = false

    /// 是否正在执行一键依次授权
    @Published public var isRequestingAll: Bool = false

    private let locationManager = CLLocationManager()
    private let eventStore = EKEventStore()
    private let motionManager = CMMotionActivityManager()

    private override init() {
        super.init()
        locationManager.delegate = self
        refreshAllStatuses()
    }

    // MARK: - 集中刷新所有权限状态

    /// 刷新所有权限状态
    public func refreshAllStatuses() {
        // 1. 系统通知
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.notificationStatus = .authorized
                case .denied:
                    self.notificationStatus = .denied
                case .notDetermined:
                    self.notificationStatus = .notDetermined
                @unknown default:
                    self.notificationStatus = .notDetermined
                }
            }
        }

        // 2. 地理定位
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            self.locationStatus = .authorized
        case .denied, .restricted:
            self.locationStatus = .denied
        case .notDetermined:
            self.locationStatus = .notDetermined
        @unknown default:
            self.locationStatus = .notDetermined
        }

        // 3. 麦克风
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            self.microphoneStatus = .authorized
        case .denied:
            self.microphoneStatus = .denied
        case .undetermined:
            self.microphoneStatus = .notDetermined
        @unknown default:
            self.microphoneStatus = .notDetermined
        }

        // 4. 语音识别
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            self.speechStatus = .authorized
        case .denied, .restricted:
            self.speechStatus = .denied
        case .notDetermined:
            self.speechStatus = .notDetermined
        @unknown default:
            self.speechStatus = .notDetermined
        }

        // 5. 相册照片
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            self.photoStatus = .authorized
        case .limited:
            self.photoStatus = .limited
        case .denied, .restricted:
            self.photoStatus = .denied
        case .notDetermined:
            self.photoStatus = .notDetermined
        @unknown default:
            self.photoStatus = .notDetermined
        }

        // 6. 相机
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraStatus = .authorized
        case .denied, .restricted:
            self.cameraStatus = .denied
        case .notDetermined:
            self.cameraStatus = .notDetermined
        @unknown default:
            self.cameraStatus = .notDetermined
        }

        // 7. 系统日历
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            self.calendarStatus = .authorized
        case .writeOnly:
            self.calendarStatus = .limited
        case .denied, .restricted:
            self.calendarStatus = .denied
        case .notDetermined:
            self.calendarStatus = .notDetermined
        @unknown default:
            self.calendarStatus = .notDetermined
        }

        // 8. 运动与健身
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized:
            self.motionStatus = .authorized
        case .denied, .restricted:
            self.motionStatus = .denied
        case .notDetermined:
            self.motionStatus = .notDetermined
        @unknown default:
            self.motionStatus = .notDetermined
        }

        // 9. Apple 健康
        refreshHealthStatus()
    }

    /// 刷新健康权限状态
    public func refreshHealthStatus() {
        guard HealthKitService.isAvailable else {
            self.healthStatus = .denied
            return
        }

        if let snapshot = HealthKitService.shared.snapshot, snapshot.readState == .hasData {
            self.healthStatus = .authorized
            return
        }

        if HealthKitService.shared.hasRequestedAuthorization {
            self.healthStatus = .authorized
            return
        }

        Task {
            let needs = await HealthKitService.shared.needsAuthorizationRequest()
            DispatchQueue.main.async {
                self.healthStatus = needs ? .notDetermined : .authorized
            }
        }
    }

    // MARK: - 集中赋予：单项权限申请

    /// 申请系统通知权限
    public func requestNotification() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            self.notificationStatus = granted ? .authorized : .denied
        } catch {
            self.notificationStatus = .denied
        }
    }

    /// 申请定位权限
    public func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// 申请麦克风与端侧语音识别权限
    public func requestMicrophoneAndSpeech() async {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        self.microphoneStatus = micGranted ? .authorized : .denied

        let speechGranted: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        self.speechStatus = speechGranted ? .authorized : .denied
    }

    /// 申请相册读写权限
    public func requestPhotoLibrary() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized: self.photoStatus = .authorized
        case .limited: self.photoStatus = .limited
        default: self.photoStatus = .denied
        }
    }

    /// 申请相机拍摄权限
    public func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        self.cameraStatus = granted ? .authorized : .denied
    }

    /// 申请系统日历访问权限
    public func requestCalendar() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            self.calendarStatus = granted ? .authorized : .denied
        } catch {
            self.calendarStatus = .denied
        }
    }

    /// 申请运动与健身感知权限
    public func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable() else {
            self.motionStatus = .denied
            return
        }
        await withCheckedContinuation { cont in
            motionManager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in
                switch CMMotionActivityManager.authorizationStatus() {
                case .authorized: self.motionStatus = .authorized
                case .denied, .restricted: self.motionStatus = .denied
                default: self.motionStatus = .notDetermined
                }
                cont.resume()
            }
        }
    }

    /// 申请 Apple 健康数据权限
    public func requestHealth() async {
        guard HealthKitService.isAvailable else { return }
        await HealthKitService.shared.requestAuthorization()
        await HealthKitService.shared.refreshToday()
        refreshHealthStatus()
    }

    /// 打开系统设置界面
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 集中赋予：一键按序快速开启所有未决权限

    /// 一键按序依次申请所有未决权限
    public func requestAllPermissionsSequence() async {
        isRequestingAll = true
        defer { isRequestingAll = false }

        // 1. 通知
        if notificationStatus == .notDetermined {
            await requestNotification()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 2. 定位
        if locationStatus == .notDetermined {
            requestLocation()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 3. 麦克风与语音
        if microphoneStatus == .notDetermined || speechStatus == .notDetermined {
            await requestMicrophoneAndSpeech()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 4. 相册
        if photoStatus == .notDetermined {
            await requestPhotoLibrary()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 5. Apple 健康
        if healthStatus == .notDetermined {
            await requestHealth()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 6. 相机
        if cameraStatus == .notDetermined {
            await requestCamera()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 7. 日历
        if calendarStatus == .notDetermined {
            await requestCalendar()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // 8. 运动与健身
        if motionStatus == .notDetermined {
            await requestMotion()
        }

        refreshAllStatuses()
    }

    // MARK: - 统计与判定

    /// 总核心功能权限项数（8 大核心能力）
    public var totalCount: Int { 8 }

    /// 已就绪的权限数量
    public var readyCount: Int {
        var count = 0
        if notificationStatus.isReady { count += 1 }
        if locationStatus.isReady { count += 1 }
        if microphoneStatus.isReady && speechStatus.isReady { count += 1 }
        if photoStatus.isReady { count += 1 }
        if healthStatus.isReady { count += 1 }
        if cameraStatus.isReady { count += 1 }
        if calendarStatus.isReady { count += 1 }
        if motionStatus.isReady { count += 1 }
        return count
    }

    /// 是否所有核心权限均已就绪
    public var areAllCorePermissionsReady: Bool {
        readyCount >= totalCount
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationStatus = .authorized
            case .denied, .restricted:
                self.locationStatus = .denied
            case .notDetermined:
                self.locationStatus = .notDetermined
            @unknown default:
                self.locationStatus = .notDetermined
            }
        }
    }
}
