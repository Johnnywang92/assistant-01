import AssistantCore
import MultipeerConnectivity
import SwiftUI
import UIKit

/// 面对面碰一碰与离线二维码分享综合面板
///
/// 具备「碰一碰雷达直传」与「面对面扫码」双通道自由切换
struct NearbyInteractionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var nearbyService = NearbyShareService.shared

    let envelope: UniversalShareEnvelope

    enum ShareChannel: String, CaseIterable, Identifiable {
        case nearby = "碰一碰直传"
        case qrCode = "面对面二维码"

        var id: String { rawValue }
    }

    @State private var selectedChannel: ShareChannel = .nearby
    @State private var qrImage: UIImage?
    @State private var radarPulse: Bool = false
    @State private var incomingEnvelopeForPreview: UniversalShareEnvelope?
    @State private var airdropItems: [Any] = []
    @State private var showAirDropSheet: Bool = false
    @State private var toastMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部通道选择器
                Picker("传输通道", selection: $selectedChannel) {
                    ForEach(ShareChannel.allCases) { channel in
                        Text(channel.rawValue).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 核心业务内容摘要条
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                // 切换通道显示
                if selectedChannel == .nearby {
                    nearbyRadarView
                } else {
                    qrCodeView
                }

                Spacer()

                // 底部补充交互：复制微信口令 & AirDrop .assistant 文件
                HStack(spacing: 12) {
                    Button {
                        copyShareToken()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("复制微信口令")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        shareViaAirDrop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "airdrop")
                            Text("AirDrop 文件")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(.systemBackground).shadow(color: .black.opacity(0.04), radius: 4, y: -2))
            }
            .navigationTitle("面对面互联")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                nearbyService.startSession()
                generateQRCodeImage()
            }
            .onDisappear {
                nearbyService.stopSession()
            }
            .sheet(item: $incomingEnvelopeForPreview) { incoming in
                UniversalImportPreviewSheet(envelope: incoming)
            }
            .sheet(isPresented: $showAirDropSheet, onDismiss: { airdropItems = [] }) {
                ShareActivityView(activityItems: airdropItems)
            }
            .onChange(of: nearbyService.receivedEnvelope) { _, newEnvelope in
                if let newEnvelope {
                    self.incomingEnvelopeForPreview = newEnvelope
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 72)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
    }

    // MARK: - 载荷摘要标头

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: envelope.type.systemIcon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(envelope.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitleForPayload)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private var subtitleForPayload: String {
        switch envelope.type {
        case .todos:
            return "包含 \(envelope.todos?.count ?? 0) 项待办事宜"
        case .expenseAA:
            if let aa = envelope.expenseAA {
                return "AA 每人分摊 ¥\(String(format: "%.2f", aa.splitAmount))（共 \(aa.splitCount) 人）"
            }
            return "AA 账单分摊"
        case .parcelTransfer:
            if let p = envelope.parcel {
                return "取件码: \(p.pickupCode)"
            }
            return "快递代取转交"
        case .emotionPulse:
            return "今日身心情绪状态共振"
        case .storageItem:
            if let s = envelope.storage {
                return "\(s.roomArea) · \(s.location)"
            }
            return "物品收纳位置"
        }
    }

    // MARK: - 碰一碰雷达视图

    private var nearbyRadarView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 10)

            // 声波雷达动画区域
            ZStack {
                // 外圈脉冲涟漪
                Circle()
                    .stroke(Color.accentColor.opacity(radarPulse ? 0.0 : 0.35), lineWidth: 2)
                    .frame(width: 190, height: 190)
                    .scaleEffect(radarPulse ? 1.45 : 0.85)

                Circle()
                    .stroke(Color.accentColor.opacity(radarPulse ? 0.05 : 0.45), lineWidth: 1.5)
                    .frame(width: 140, height: 140)
                    .scaleEffect(radarPulse ? 1.25 : 0.95)

                // 中心呼吸底座
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 90, height: 90)

                Image(systemName: "wave.3.forward.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 170)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    radarPulse = true
                }
            }

            // 状态提示文字
            VStack(spacing: 4) {
                if let peerName = nearbyService.sendSuccessPeer {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已成功投送给「\(peerName)」！")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                } else if nearbyService.isSending {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text("正在传输至附近设备...")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                } else if nearbyService.discoveredPeers.isEmpty {
                    Text("两台手机靠近即可自组网，无需外网或蓝牙配对")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("发现附近设备，点击头像即可秒级投送")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }

                if let err = nearbyService.lastErrorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                }
            }

            // 附近发现的设备列表
            VStack(spacing: 10) {
                if nearbyService.discoveredPeers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title3)
                            .foregroundStyle(Color(.systemGray3))
                        Text("正在搜寻附近开启小助的用户...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .background(Color(.secondarySystemGroupedBackground).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                } else {
                    ForEach(nearbyService.discoveredPeers, id: \.self) { peer in
                        Button {
                            nearbyService.send(envelope: envelope, to: peer)
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 44, height: 44)

                                    Image(systemName: "iphone.gen3")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(nearbyService.connectedPeers.contains(peer) ? "已直连" : "轻触投送")
                                        .font(.caption2)
                                        .foregroundStyle(nearbyService.connectedPeers.contains(peer) ? .green : .secondary)
                                }

                                Spacer()

                                Image(systemName: "paperplane.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(8)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 面对面二维码视图

    private var qrCodeView: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 10)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 230, height: 230)
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
            } else {
                ProgressView()
                    .frame(width: 230, height: 230)
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(Color.accentColor)
                    Text("让对方打开小助「扫一扫」即可接收")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }

                Text("纯本地视觉光学传输 · 零网络与蓝牙依赖")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    private func generateQRCodeImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = QRCodeService.generateQRCode(from: envelope, targetSize: 420)
            DispatchQueue.main.async {
                self.qrImage = img
            }
        }
    }

    private func copyShareToken() {
        let text = envelope.generateShareText()
        UIPasteboard.general.string = text
        Haptic.success()
        toastMessage = "已复制小助分享口令，发给微信好友后对方打开 App 即可直接导入！"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if toastMessage?.contains("小助分享口令") == true {
                toastMessage = nil
            }
        }
    }

    private func shareViaAirDrop() {
        if let fileURL = AssistantPackageService.createPackageFile(for: envelope) {
            self.airdropItems = [fileURL]
            self.showAirDropSheet = true
            Haptic.selection()
        }
    }
}
