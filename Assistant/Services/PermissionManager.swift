import AVFoundation
import CoreLocation
import Foundation
import Photos
import Speech
import SwiftUI
import UIKit
import UserNotifications

/// 全局权限管理与健康度检测中心
@MainActor
public final class PermissionManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = PermissionManager()

    public enum PermissionState: Equatable {
        case authorized
        case denied
        case notDetermined
        case limited

        public var isReady: Bool {
            self == .authorized || self == .limited
        }
    }

    // 5 项关键权限的实时状态
    @Published public var notificationStatus: PermissionState = .notDetermined
    @Published public var locationStatus: PermissionState = .notDetermined
    @Published public var microphoneStatus: PermissionState = .notDetermined
    @Published public var speechStatus: PermissionState = .notDetermined
    @Published public var photoStatus: PermissionState = .notDetermined

    /// 是否已展示/完成初次权限引导
    @AppStorage("has_completed_permission_onboarding_v1") public var hasCompletedOnboarding: Bool = false

    /// 是否正在执行一键依次授权
    @Published public var isRequestingAll: Bool = false

    private let locationManager = CLLocationManager()

    private override init() {
        super.init()
        locationManager.delegate = self
        refreshAllStatuses()
    }

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

        // 5. 相册
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
    }

    // MARK: - 单项权限申请

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
        // 麦克风
        let micGranted = await AVAudioApplication.requestRecordPermission()
        self.microphoneStatus = micGranted ? .authorized : .denied

        // 语音识别
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

    /// 打开系统设置界面
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// 一键按序快速引导申请所有未决权限
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
        }

        refreshAllStatuses()
    }

    /// 已就绪的核心权限数量
    public var readyCount: Int {
        var count = 0
        if notificationStatus.isReady { count += 1 }
        if locationStatus.isReady { count += 1 }
        if microphoneStatus.isReady && speechStatus.isReady { count += 1 }
        if photoStatus.isReady { count += 1 }
        return count
    }

    /// 是否所有核心权限均已就绪
    public var areAllCorePermissionsReady: Bool {
        readyCount >= 4
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
