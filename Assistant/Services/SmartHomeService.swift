import Foundation
import HomeKit

/// 智能家居离线联动服务（通过 iOS 原生 HomeKit 框架直连家庭中枢）
@MainActor
final class SmartHomeService: NSObject, ObservableObject {
    static let shared = SmartHomeService()

    private var homeManager: HMHomeManager?
    @Published var availableHomes: [String] = []
    @Published var availableScenes: [String] = []
    @Published var isReady = false

    private override init() {
        super.init()
        self.homeManager = HMHomeManager()
        self.homeManager?.delegate = self
    }

    /// 执行指定的智能家居场景（如："扫地机器人清扫"、"出门关闭所有灯"、"回家模式"）
    func triggerScene(named sceneName: String) async -> Bool {
        guard let manager = homeManager else { return false }

        for home in manager.homes {
            if let actionSet = home.actionSets.first(where: { $0.name == sceneName }) {
                do {
                    try await home.executeActionSet(actionSet)
                    return true
                } catch {
                    return false
                }
            }
        }
        return false
    }
}

// MARK: - HMHomeManagerDelegate
extension SmartHomeService: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.availableHomes = manager.homes.map(\.name)
            var scenes: [String] = []
            for home in manager.homes {
                scenes.append(contentsOf: home.actionSets.map(\.name))
            }
            self.availableScenes = scenes
            self.isReady = true
        }
    }
}
