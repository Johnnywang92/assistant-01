// swift-tools-version:5.10
import PackageDescription

// 纯逻辑模块：短信规则解析、待办匹配。不依赖 UIKit/SwiftData，可在 macOS 上直接 `swift test`。
let package = Package(
    name: "AssistantCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
    ],
    targets: [
        .target(name: "AssistantCore", resources: [.process("Resources")]),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"]),
    ]
)
