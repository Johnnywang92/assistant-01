import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI

/// 相机扫描取景器控制器 (UIKit 封装)
struct CameraScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCodeFound = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCodeFound: ((String) -> Void)?
        private var captureSession: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var isScanning = true

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            setupCamera()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isScanning = true
            if let session = captureSession, !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let session = captureSession, session.isRunning {
                session.stopRunning()
            }
        }

        private func setupCamera() {
            let session = AVCaptureSession()
            guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
            guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else { return }

            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                return
            }

            let metadataOutput = AVCaptureMetadataOutput()
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                return
            }

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.layer.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)

            self.previewLayer = preview
            self.captureSession = session

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard isScanning else { return }
            if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
               let stringValue = metadataObject.stringValue {
                isScanning = false
                Haptic.medium()
                onCodeFound?(stringValue)
            }
        }
    }
}

/// 扫码导入二维码全屏交互页（支持实时相机取景与相册选图识别）
struct QRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var scannedCode: String?
    @State private var decodedPayload: TodoSharePayload?
    @State private var isShowingPreviewSheet: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isTorchOn: Bool = false
    @State private var errorMessage: String? = nil
    @State private var scanLineOffset: CGFloat = -110

    var body: some View {
        NavigationStack {
            ZStack {
                // 1. 底层相机取景
                CameraScannerRepresentable { code in
                    handleScannedCode(code)
                }
                .ignoresSafeArea()

                // 2. 取景遮罩与对准线框
                VStack(spacing: 0) {
                    Spacer()

                    ZStack {
                        // 四角取景框
                        RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                            .stroke(Color.white.opacity(0.85), lineWidth: 3)
                            .frame(width: 260, height: 260)

                        // 扫描上下浮动动画激光线
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.0), Color.accentColor, Color.accentColor.opacity(0.0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 240, height: 3)
                            .offset(y: scanLineOffset)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                                    scanLineOffset = 110
                                }
                            }
                    }

                    Text("将二维码放入框内，或从相册选择预约截图导入")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .shadow(radius: 4)

                    Spacer()

                    // 3. 底部操作栏（手电筒与相册选择）
                    HStack(spacing: 48) {
                        // 手电筒开关
                        Button {
                            toggleTorch()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.title2)
                                    .foregroundStyle(isTorchOn ? .yellow : .white)
                                    .frame(width: 52, height: 52)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())

                                Text(isTorchOn ? "关闭照明" : "打开手电")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                            }
                        }

                        // 从相册选取识别
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 52, height: 52)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())

                                Text("相册选图")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("扫码导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .sheet(isPresented: $isShowingPreviewSheet, onDismiss: {
                // 导入成功或关闭后退回首页
                dismiss()
            }) {
                if let payload = decodedPayload {
                    TodoImportPreviewSheet(payload: payload) {
                        dismiss()
                    }
                }
            }
            .alert("识别提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        if let detectedCode = QRCodeService.detectQRCode(from: uiImage),
                           let payload = QRCodeService.decodePayload(from: detectedCode) {
                            await MainActor.run {
                                self.decodedPayload = payload
                                self.isShowingPreviewSheet = true
                            }
                        } else if let result = try? await OCRService.shared.recognizeTodo(from: uiImage),
                                  !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await MainActor.run {
                                let minOrder = TodoItem.minimumSortOrder(in: context)
                                let item = TodoItem(
                                    type: result.type,
                                    status: .active,
                                    title: result.title,
                                    detail: result.detail,
                                    pickupCode: result.pickupCode,
                                    station: result.station ?? result.location,
                                    location: result.location ?? result.station,
                                    dueAt: result.dueAt,
                                    sourceText: result.rawText,
                                    sortOrder: minOrder - 1,
                                    remindBeforeMinutes: result.dueAt != nil ? 60 : 0,
                                    qrCodePayload: result.qrCodePayload,
                                    qrCodeImageData: result.qrCodeImageData,
                                    attachmentImageData: result.attachmentImageData
                                )
                                context.insert(item)
                                TodoNotificationManager.shared.scheduleNotification(for: item)
                                try? context.save()
                                Haptic.success()
                                dismiss()
                            }
                        } else {
                            await MainActor.run {
                                errorMessage = "所选图片中未检测到有效二维码或可识别的待办信息，请换一张清晰图片重试。"
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleScannedCode(_ rawCode: String) {
        if let payload = QRCodeService.decodePayload(from: rawCode) {
            self.decodedPayload = payload
            self.isShowingPreviewSheet = true
        } else {
            errorMessage = "该二维码非小助待办分享码，若为门票/预约截图请点击底部「相册选图」识别导入。"
        }
    }

    private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = isTorchOn ? .off : .on
            isTorchOn.toggle()
            device.unlockForConfiguration()
            Haptic.light()
        } catch {
            print("Torch error: \(error)")
        }
    }
}
