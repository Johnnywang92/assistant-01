import AssistantCore
import Foundation

/// 推理后端注册表：谁能被尝试、按什么顺序尝试。
///
/// 顺序的**唯一真相在 Core**（`InferenceBackendID.attemptOrder`），这里只把身份映射到实现，
/// 并在 DEBUG 下双向校验：Core 声明的后端必须有实现、实现不得多出、顺序里的每一格都要给得出实现。
/// 新增后端 = Core 一个 case（同时回答三个能力位）+ 一个实现 + 下面 `all` 一行。
/// 漏掉任何一步都会在首次派发时断言，而不是静默少一条降级路径。
enum InferenceBackendRegistry {

    static let all: [any InferenceBackend] = [
        OnDeviceGgufBackend(),
        RemoteOllamaBackend()
    ]

    /// 按 Core 申报的降级顺序给出的实现。编排层遍历这个列表，不再各写各的 if/else。
    static var attemptOrder: [any InferenceBackend] {
        InferenceBackendID.attemptOrder.compactMap { backend(for: $0) }
    }

    static func backend(for id: InferenceBackendID) -> (any InferenceBackend)? {
        #if DEBUG
        assert(contractIssues.isEmpty, "推理后端注册表与 Core 契约不一致：\(contractIssues)")
        #endif
        return all.first { $0.id == id }
    }

    #if DEBUG
    /// 注册表自检。刻意不调用 `backend(for:)`——那个方法会反过来断言本表为空。
    private static let contractIssues: [String] = {
        var issues: [String] = []
        var seen = Set<InferenceBackendID>()
        for backend in all {
            if !seen.insert(backend.id).inserted {
                issues.append("后端重复注册实现：\(backend.id.rawValue)")
            }
        }
        for id in InferenceBackendID.allCases where !seen.contains(id) {
            issues.append("Core 声明了后端 \(id.rawValue) 但没有实现")
        }
        for id in seen where !InferenceBackendID.allCases.contains(id) {
            issues.append("实现的后端 \(id.rawValue) 不在 Core 声明的清单里")
        }
        for id in InferenceBackendID.attemptOrder where !seen.contains(id) {
            issues.append("尝试顺序里有 \(id.rawValue)，但注册表给不出实现")
        }
        return issues
    }()
    #endif
}
