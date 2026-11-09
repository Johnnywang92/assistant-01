import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit

/// Apple Watch 侧状态与 WatchConnectivity 同步总控
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var displaySnapshot: WidgetSnapshot = .empty
    @Published private(set) var baseSnapshot: WidgetSnapshot = .empty
    @Published private(set) var pendingEnvelopes: [WatchCommandEnvelope] = []
    @Published private(set) var isReachable: Bool = false
    @Published var lastReplyBanner: String?
    @Published var selectedTab: WatchTab = .today

    private static let baseSnapshotKey = "watch_local_base_snapshot_v1"
    private static let pendingEnvelopesKey = "watch_pending_envelopes_v1"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetBridgeConstants.appGroupID) ?? .standard
    }

    private override init() {
        super.init()
        loadPersistedState()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - 本地持久化与对账

    private func loadPersistedState() {
        if let data = defaults.data(forKey: Self.baseSnapshotKey),
           let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            self.baseSnapshot = snap
        } else {
            self.baseSnapshot = WidgetSnapshotStore.load()
        }

        if let data = defaults.data(forKey: Self.pendingEnvelopesKey),
           let pending = try? JSONDecoder().decode([WatchCommandEnvelope].self, from: data) {
            self.pendingEnvelopes = pending
        }

        recomputeDisplaySnapshot()
    }

    private func savePersistedState() {
        if let data = try? JSONEncoder().encode(baseSnapshot) {
            defaults.set(data, forKey: Self.baseSnapshotKey)
        }
        if let data = try? JSONEncoder().encode(pendingEnvelopes) {
            defaults.set(data, forKey: Self.pendingEnvelopesKey)
        }
        WidgetSnapshotStore.save(displaySnapshot)
    }

    private func recomputeDisplaySnapshot() {
        var display = baseSnapshot
        for env in pendingEnvelopes {
            WatchSyncReconciler.applyOptimistically(env.command, to: &display)
        }
        self.displaySnapshot = display
        WidgetSnapshotStore.save(display)
    }

    func applyRemoteSnapshotData(_ data: Data) {
        guard let remote = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        let result = WatchSyncReconciler.reconcile(
            remoteSnapshot: remote,
            localBaseSnapshot: baseSnapshot,
            pendingEnvelopes: pendingEnvelopes
        )
        self.baseSnapshot = result.baseSnapshot
        self.displaySnapshot = result.displaySnapshot
        self.pendingEnvelopes = result.remainingPending
        savePersistedState()
    }

    // MARK: - 发送指令与乐观更新

    func sendCommand(_ command: WidgetCommand, feedbackToast: String? = nil) {
        let envelope = WatchCommandEnvelope(command: command)
        pendingEnvelopes.append(envelope)
        recomputeDisplaySnapshot()
        savePersistedState()

        WKInterfaceDevice.current().play(.success)
        if let feedbackToast {
            showBanner(feedbackToast)
        }

        guard let encoded = try? JSONEncoder().encode(envelope) else { return }
        let payload: [String: Any] = [WatchSyncReconciler.commandEnvelopeKey: encoded]

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        if session.isReachable {
            session.sendMessage(payload) { [weak self] response in
                Task { @MainActor in
                    guard let self else { return }
                    if let snapData = response[WatchSyncReconciler.snapshotContextKey] as? Data {
                        self.applyRemoteSnapshotData(snapData)
                    }
                    if let reply = response[WatchSyncReconciler.commandReplyKey] as? String, !reply.isEmpty {
                        self.showBanner(reply)
                    }
                }
            } errorHandler: { _ in
                // 在线发送失败时自动降级到保证送达队列
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func requestRefresh() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // 先尝试从已送达的 applicationContext 恢复
        if let ctxData = session.receivedApplicationContext[WatchSyncReconciler.snapshotContextKey] as? Data {
            applyRemoteSnapshotData(ctxData)
        }

        guard session.isReachable else { return }
        session.sendMessage(["request": "refreshSnapshot"]) { [weak self] response in
            Task { @MainActor in
                if let snapData = response[WatchSyncReconciler.snapshotContextKey] as? Data {
                    self?.applyRemoteSnapshotData(snapData)
                }
            }
        } errorHandler: { _ in }
    }

    var stalePendingCount: Int {
        WatchSyncReconciler.stalePendingCount(in: pendingEnvelopes)
    }

    func showBanner(_ message: String) {
        withAnimation {
            lastReplyBanner = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.lastReplyBanner == message {
                withAnimation {
                    self.lastReplyBanner = nil
                }
            }
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if let data = session.receivedApplicationContext[WatchSyncReconciler.snapshotContextKey] as? Data {
                self.applyRemoteSnapshotData(data)
            }
            if session.isReachable {
                self.requestRefresh()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable {
                self.requestRefresh()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSyncReconciler.snapshotContextKey] as? Data else { return }
        Task { @MainActor in
            self.applyRemoteSnapshotData(data)
        }
    }
}

enum WatchTab: Hashable {
    case today
    case parcels
    case quickCapture
    case mood
    case water
}
