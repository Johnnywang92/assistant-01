import Foundation
import SwiftData
import WatchConnectivity

/// iPhone 侧与 Apple Watch 通信桥接（数据真相在 iPhone SwiftData，手表仅接收轻量快照并回传指令信封）。
@MainActor
final class PhoneWatchBridge: NSObject, ObservableObject {
    static let shared = PhoneWatchBridge()

    @Published private(set) var isWatchPaired: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var isReachable: Bool = false
    @Published private(set) var lastPushedAt: Date?

    private override init() {
        super.init()
    }

    /// 在应用启动时激活 WatchConnectivity 会话
    func activateIfSupported() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 将最新轻量快照通过 `updateApplicationContext` 推送给手表（系统自动去重只保留最新一份）
    func pushSnapshot(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        updateSessionFlags(session)
        guard session.isPaired else { return }

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try session.updateApplicationContext([
                WatchSyncReconciler.snapshotContextKey: data
            ])
            lastPushedAt = .now
        } catch {
            print("⚠️ [PhoneWatchBridge] 推送快照到 Apple Watch 失败: \(error.localizedDescription)")
        }
    }

    private func updateSessionFlags(_ session: WCSession) {
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func handleIncomingEnvelopeData(_ data: Data) async -> String {
        guard let envelope = try? JSONDecoder().decode(WatchCommandEnvelope.self, from: data) else {
            return "指令格式无效"
        }
        let context = Persistence.shared.mainContext
        return await WidgetSnapshotSyncController.shared.handleWatchCommandEnvelope(envelope, context: context)
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.updateSessionFlags(session)
            if activationState == .activated {
                let current = WidgetSnapshotStore.load()
                if current.generatedAt > .distantPast {
                    self.pushSnapshot(current)
                }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.updateSessionFlags(session)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.updateSessionFlags(session)
        }
    }

    /// 接收手表通过 `transferUserInfo` 排队发来的离线/后台指令
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchSyncReconciler.commandEnvelopeKey] as? Data else { return }
        Task { @MainActor in
            _ = await self.handleIncomingEnvelopeData(data)
        }
    }

    /// 接收手表通过 `sendMessage` 发来的在线即时指令（带回执）
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if let data = message[WatchSyncReconciler.commandEnvelopeKey] as? Data {
            Task { @MainActor in
                let replyText = await self.handleIncomingEnvelopeData(data)
                let latestSnapshot = WidgetSnapshotStore.load()
                var response: [String: Any] = [
                    WatchSyncReconciler.commandReplyKey: replyText
                ]
                if let snapData = try? JSONEncoder().encode(latestSnapshot) {
                    response[WatchSyncReconciler.snapshotContextKey] = snapData
                }
                replyHandler(response)
            }
        } else if message["request"] as? String == "refreshSnapshot" {
            Task { @MainActor in
                let context = Persistence.shared.mainContext
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
                let latestSnapshot = WidgetSnapshotStore.load()
                var response: [String: Any] = [:]
                if let snapData = try? JSONEncoder().encode(latestSnapshot) {
                    response[WatchSyncReconciler.snapshotContextKey] = snapData
                }
                replyHandler(response)
            }
        } else {
            replyHandler([:])
        }
    }
}
