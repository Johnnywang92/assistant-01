// swift-tools-version:5.10
import PackageDescription

// P0-1 数据库迁移演练包。独立于 AssistantCore：需要 @Model 宏与 SwiftData，
// 且是一次性验证工具，不进产品代码。
// 运行：cd scripts/migration-drill && swift run
let package = Package(
    name: "MigrationDrill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MigrationDrill")
    ]
)
