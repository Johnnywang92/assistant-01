import AVFoundation

/// 音频会话的设置、激活与停用都可能阻塞调用线程（挂起报告里被点名的是主线程调用），
/// 统一挪到专用串行队列：既不卡 UI，串行又能保证「停用 → 再次激活」不会乱序。
enum AudioSessionConfigurator {
    private static let queue = DispatchQueue(label: "com.yifanwang.assistant01.audio-session", qos: .userInitiated)

    /// 设置分类并激活；返回时会话已就绪
    static func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions = [],
        activationOptions: AVAudioSession.SetActiveOptions = []
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(category, mode: mode, options: options)
                    try session.setActive(true, options: activationOptions)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 按当前分类重新激活（暂停后恢复录音）
    static func reactivate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? AVAudioSession.sharedInstance().setActive(true)
                continuation.resume()
            }
        }
    }

    /// 停用不需要调用方等待，排队执行即可
    static func deactivateInBackground() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
