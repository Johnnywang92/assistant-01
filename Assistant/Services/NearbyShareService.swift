import Foundation
import MultipeerConnectivity
import SwiftUI
import UIKit

/// 面对面碰一碰（MultipeerConnectivity）底层通信服务
///
/// 具备双向自组网能力：进入碰一碰界面时同时开启广播（Advertiser）与搜寻（Browser），
/// 双方设备无需区分发送端/接收端，靠近即可毫秒级雷达发现与极速投送。
@MainActor
public final class NearbyShareService: NSObject, ObservableObject {
    public static let shared = NearbyShareService()

    /// Bonjour 协议标识（最长 15 字符，仅小写字母、数字、短横线）
    public static let serviceType = "asst-share"

    // MARK: - Published 响应式状态

    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var discoveredPeers: [MCPeerID] = []
    @Published public private(set) var connectedPeers: [MCPeerID] = []
    @Published public private(set) var isSending: Bool = false
    @Published public var sendSuccessPeer: String? = nil
    @Published public var lastErrorMessage: String? = nil

    /// 接收到的最新数据载荷（接收端收到后弹出预览确认面板）
    @Published public var receivedEnvelope: UniversalShareEnvelope? = nil

    // MARK: - Multipeer 核心组件

    private var myPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// 准备发出的暂存载荷（用于建立连接后立即自动投送）
    private var pendingEnvelopeToSend: (envelope: UniversalShareEnvelope, targetPeer: MCPeerID)?

    override private init() {
        // 使用设备用户友好名（如 "张三的 iPhone"）
        let sanitizedName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.myPeerID = MCPeerID(displayName: sanitizedName.isEmpty ? "小助设备" : sanitizedName)
        super.init()
    }

    // MARK: - 会话生命周期

    /// 开启近场自组网雷达（同时广播自己与搜寻附近）
    public func startSession() {
        guard !isSearching else { return }

        // 重置状态
        resetSession()

        let newSession = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        self.session = newSession

        let newAdvertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["v": "2"],
            serviceType: Self.serviceType
        )
        newAdvertiser.delegate = self
        newAdvertiser.startAdvertisingPeer()
        self.advertiser = newAdvertiser

        let newBrowser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        newBrowser.delegate = self
        newBrowser.startBrowsingForPeers()
        self.browser = newBrowser

        self.isSearching = true
        self.lastErrorMessage = nil
        self.sendSuccessPeer = nil
    }

    /// 停止近场会话，释放射频与广播资源
    public func stopSession() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        advertiser = nil
        browser = nil
        session = nil

        isSearching = false
        discoveredPeers.removeAll()
        connectedPeers.removeAll()
        pendingEnvelopeToSend = nil
    }

    private func resetSession() {
        stopSession()
    }

    // MARK: - 发送数据

    /// 碰一碰一键投送给指定附近设备
    public func send(envelope: UniversalShareEnvelope, to targetPeer: MCPeerID) {
        guard let session = session else {
            lastErrorMessage = "近场会话未初始化"
            return
        }

        isSending = true
        sendSuccessPeer = nil
        lastErrorMessage = nil

        // 若已连通，直接发送
        if session.connectedPeers.contains(targetPeer) {
            transmitData(envelope: envelope, to: [targetPeer])
        } else {
            // 暂存待发任务，发起近场连接邀请
            pendingEnvelopeToSend = (envelope, targetPeer)
            browser?.invitePeer(targetPeer, to: session, withContext: nil, timeout: 12)
        }
    }

    private func transmitData(envelope: UniversalShareEnvelope, to peers: [MCPeerID]) {
        guard let session = session, let data = envelope.encode() else {
            isSending = false
            lastErrorMessage = "数据打包失败"
            return
        }

        do {
            try session.send(data, toPeers: peers, with: .reliable)
            isSending = false
            if let first = peers.first {
                sendSuccessPeer = first.displayName
            }
            Haptic.success()
        } catch {
            isSending = false
            lastErrorMessage = "投送失败: \(error.localizedDescription)"
            Haptic.error()
        }
    }

    public func clearReceived() {
        receivedEnvelope = nil
    }
}

// MARK: - MCSessionDelegate

extension NearbyShareService: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                Haptic.light()

                // 若有排队等待向此 peer 发送的载荷，连通瞬间触发投送
                if let pending = self.pendingEnvelopeToSend, pending.targetPeer == peerID {
                    self.transmitData(envelope: pending.envelope, to: [peerID])
                    self.pendingEnvelopeToSend = nil
                }

            case .connecting:
                break

            case .notConnected:
                self.connectedPeers.removeAll(where: { $0 == peerID })
                if self.pendingEnvelopeToSend?.targetPeer == peerID {
                    self.isSending = false
                    self.lastErrorMessage = "与 \(peerID.displayName) 连接中断"
                    self.pendingEnvelopeToSend = nil
                }

            @unknown default:
                break
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if let envelope = UniversalShareEnvelope.decode(from: data) {
                self.receivedEnvelope = envelope
                Haptic.medium()
            } else if let legacyPayload = QRCodeService.decodePayload(from: String(data: data, encoding: .utf8) ?? "") {
                // 兼容旧待办载荷
                let converted = UniversalShareEnvelope(
                    senderName: peerID.displayName,
                    type: .todos,
                    title: legacyPayload.title,
                    todos: legacyPayload.items
                )
                self.receivedEnvelope = converted
                Haptic.medium()
            } else {
                self.lastErrorMessage = "收到来自 \(peerID.displayName) 的未知数据包"
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NearbyShareService: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // 在碰一碰面板开启状态下，自动接受来自小助协议的对等设备握手邀请
            guard let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
        }
    }

    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = "近场广播启动失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NearbyShareService: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.discoveredPeers.contains(peerID) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    self.discoveredPeers.append(peerID)
                }
                Haptic.selection()
            }
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                self.discoveredPeers.removeAll(where: { $0 == peerID })
            }
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = "近场搜寻启动失败: \(error.localizedDescription)"
        }
    }
}
