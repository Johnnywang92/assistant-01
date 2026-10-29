// swift-tools-version:5.10
import PackageDescription

// P0-1 数据库迁移演练包。独立于 AssistantCore：需要 @Model 宏与 SwiftData，
// 且是一次性验证工具，不进产品代码。
// 运行：cd scripts/migration-drill && swift run
// 平台下限保持 macOS 14（tools-version 5.10 没有 .v15）；演练 5 的 `#Index` 部分用
// `@available(macOS 15, *)` + 运行时判等门控，在低版本主机上跳过而不是失败。
let package = Package(
    name: "MigrationDrill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MigrationDrill")
    ]
)
