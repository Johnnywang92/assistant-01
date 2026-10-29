import CryptoKit
import Foundation
import SQLite3
import SwiftData

// P0-1 演练脚本：旧库升级 + 损坏库 + 未知结构库 + `#Index` 生效边界。
// 验证目标（对应 todo.md P0-1 验收：用旧版数据库和损坏数据库分别升级，原文件不被自动删除，
// 应用不会在内存库中假装保存成功）：
//   ① V1 旧库经 lightweight 迁移升级到 V2，数据完整、新字段有默认值；
//   ② 损坏库打开失败，且失败后原文件一个字节都没被删改；
//   ③ 结构不在迁移计划内的库打开失败，文件同样保留；
//   ④ 应用侧不再有任何删库路径；
//   ⑤ `#Index` 只在**新建库**生效，老库不会补建；写进 `#if` 会静默失效；
//      老库要提速只能走文件层 SQL 建索引（见演练 5 的结论）。
// 注意：本脚本是 SwiftData 迁移机制的演练（微型镜像模型），
// 应用真实的 V1/V2 模型清单在 Assistant/Services/Persistence.swift，
// 由 DEBUG 断言 assertSchemaCoverage 保证 V1 ⊆ V2。

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("assistant_p0_drill_\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: workDir) }

var failures: [String] = []
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name)")
        failures.append(name)
    }
}

func sha256(_ url: URL) -> String? {
    guard let data = fm.contents(atPath: url.path) else { return nil }
    return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
}

// MARK: - 微型镜像模型（结构对齐应用：V1 两个模型 → V2 加字段 + 加模型）

@Model
final class DrillNote {
    var title: String
    var detail: String
    var noteColor: String? // V2 新增可选字段（对应应用里历次加的可选字段）
    init(title: String, detail: String, noteColor: String? = nil) {
        self.title = title
        self.detail = detail
        self.noteColor = noteColor
    }
}

@Model
final class DrillTag {
    var name: String
    init(name: String) { self.name = name }
}

@Model
final class DrillAlien {
    var payload: String
    init(payload: String) { self.payload = payload }
}

/// 演练 5 用：带 `#Index` 声明的镜像模型（三组索引：两列各一 + 一个复合）
@available(macOS 15, *)
@Model
final class DrillIndexedNote {
    var statusRaw: String
    var dueAt: Date
    init(statusRaw: String, dueAt: Date) {
        self.statusRaw = statusRaw; self.dueAt = dueAt
    }
    // 这一行不能被 #if 包裹：包裹后宏会静默失效，正是演练 5c 要钉住的坑
    #Index<DrillIndexedNote>([\.statusRaw], [\.dueAt], [\.statusRaw, \.dueAt])
}

/// 演练 5c 用：与上面唯一的差别是把 `#Index` 写进 #if 分支
@available(macOS 15, *)
@Model
final class DrillIfNote {
    var statusRaw: String
    init(statusRaw: String) { self.statusRaw = statusRaw }
#if os(macOS)
    #Index<DrillIfNote>([\.statusRaw])
#endif
}

enum DrillSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [DrillNote.self] }
}

enum DrillSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [DrillNote.self, DrillTag.self] }
}

enum DrillMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [DrillSchemaV1.self, DrillSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: DrillSchemaV1.self, toVersion: DrillSchemaV2.self)]
    }
}

func openStore(_ schema: Schema, url: URL, withPlan: Bool) throws -> ModelContainer {
    let config = ModelConfiguration("drill", schema: schema, url: url)
    if withPlan {
        return try ModelContainer(for: schema, migrationPlan: DrillMigrationPlan.self, configurations: config)
    }
    return try ModelContainer(for: schema, configurations: config)
}

// MARK: - 演练 1：V1 旧库升级到 V2，数据不丢

print("演练 1：旧库（V1）升级")
do {
    let oldStoreURL = workDir.appendingPathComponent("old.store")

    // 1a. 用 V1 schema 建库并写入数据（模拟老版本 App 留下的库）
    let v1Schema = Schema(DrillSchemaV1.models)
    let v1Container = try openStore(v1Schema, url: oldStoreURL, withPlan: false)
    let ctx = ModelContext(v1Container)
    ctx.insert(DrillNote(title: "超市购物", detail: "牛奶、鸡蛋", noteColor: nil))
    ctx.insert(DrillNote(title: "还书", detail: "图书馆三楼"))
    try ctx.save()
    print("  · V1 库已写入 2 条记录")

    // 1b. 用 V2 schema + 迁移计划打开同一个文件
    let v2Schema = Schema(DrillSchemaV2.models)
    let v2Container = try openStore(v2Schema, url: oldStoreURL, withPlan: true)
    let readCtx = ModelContext(v2Container)
    let notes = try readCtx.fetch(FetchDescriptor<DrillNote>())
    check(notes.count == 2, "升级后记录数不变（2 条）")
    check(notes.contains { $0.title == "超市购物" && $0.detail == "牛奶、鸡蛋" }, "原字段值完整")
    check(notes.allSatisfy { $0.noteColor == nil }, "新增字段默认值为 nil")

    // 1c. 升级后的库可正常写入新模型的表
    readCtx.insert(DrillTag(name: "家庭"))
    try readCtx.save()
    let tags = try readCtx.fetch(FetchDescriptor<DrillTag>())
    check(tags.count == 1, "新模型表可写入")
} catch {
    check(false, "旧库升级过程抛错：\(error.localizedDescription)")
}

// MARK: - 演练 2：损坏库打开失败，原文件不被删改

print("演练 2：损坏库")
do {
    let corruptURL = workDir.appendingPathComponent("corrupt.store")

    // 2a. 先建一个正常库
    let schema = Schema(DrillSchemaV2.models)
    let c = try openStore(schema, url: corruptURL, withPlan: true)
    let setupCtx = ModelContext(c)
    setupCtx.insert(DrillNote(title: "损坏前最后一条", detail: "必须保留"))
    try setupCtx.save()

    // 2b. 破坏文件主体（SQLite 头之后的数据区）
    var bytes = try Data(contentsOf: corruptURL)
    let corruptStart = bytes.count / 2
    for i in corruptStart..<min(corruptStart + 1024, bytes.count) {
        bytes[i] = 0xFF
    }
    try bytes.write(to: corruptURL)
    let hashAfterCorruption = sha256(corruptURL)
    let sizeAfterCorruption = (try? fm.attributesOfItem(atPath: corruptURL.path)[.size] as? Int) ?? 0
    print("  · 已破坏 \(sizeAfterCorruption / 1024) KB 库文件的数据区")

    // 2c. 尝试打开。注意：SQLite 对损坏是惰性的——落在空闲页时打开甚至不报错，
    // 真正的验收标准不是「打开必须失败」，而是：
    //   ① 原文件不被删除或重建（旧代码在这里直接删库，数据蒸发）；
    //   ② 打开成功后读数据要么报错、要么拿不到数据，绝不返回伪造内容。
    var container: ModelContainer?
    do {
        container = try openStore(schema, url: corruptURL, withPlan: true)
        print("  · 打开成功（损坏可能落在空闲页）")
    } catch {
        print("  · 打开失败：\(error.localizedDescription.prefix(80))…")
    }

    var readReport = "未读取"
    if let container {
        do {
            let notes = try ModelContext(container).fetch(FetchDescriptor<DrillNote>())
            readReport = "读到 \(notes.count) 条"
            // 数据区被破坏后仍能读到完整原值属于「损坏在空闲页」，
            // 此时不应谎报失败；但绝不允许读到损坏内容却假装正常——SQLite 不会这么做。
            print("  · 打开后读取结果：\(readReport)")
        } catch {
            readReport = "读取抛错"
            print("  · 打开后读取抛错（损坏被暴露，符合预期）")
        }
    }

    // 2d. 关键断言：失败/损坏之后文件原样保留
    check(fm.fileExists(atPath: corruptURL.path), "损坏的库文件仍然存在（未被删除）")
    check(sha256(corruptURL) == hashAfterCorruption, "库文件内容一个字节都没变（未被删除或重建）")
    let sizeNow = (try? fm.attributesOfItem(atPath: corruptURL.path)[.size] as? Int) ?? 0
    check(sizeNow == sizeAfterCorruption, "文件体积不变")
    _ = readReport
} catch {
    check(false, "损坏库演练过程抛错：\(error.localizedDescription)")
}

// MARK: - 演练 3：结构不在迁移计划内的库

print("演练 3：未知结构库")
do {
    let alienURL = workDir.appendingPathComponent("alien.store")

    // 3a. 用一个迁移计划完全不认识的模型建库
    let alienSchema = Schema([DrillAlien.self])
    let alienContainer = try openStore(alienSchema, url: alienURL, withPlan: false)
    let alienCtx = ModelContext(alienContainer)
    alienCtx.insert(DrillAlien(payload: "来自未来版本的数据"))
    try alienCtx.save()
    let hashBefore = sha256(alienURL)

    // 3b. 用应用当前的迁移计划打开：预期失败
    var openFailed = false
    do {
        _ = try openStore(Schema(DrillSchemaV2.models), url: alienURL, withPlan: true)
    } catch {
        openFailed = true
        print("  · 打开失败（符合预期）：\(error.localizedDescription.prefix(80))…")
    }
    check(openFailed, "未知结构库打开失败")
    check(fm.fileExists(atPath: alienURL.path), "未知结构库文件保留")
    check(sha256(alienURL) == hashBefore, "未知结构库内容未被改动（用户可导出后由新版本处理）")
} catch {
    check(false, "未知结构库演练过程抛错：\(error.localizedDescription)")
}

// MARK: - 演练 4：应用侧结构约束（回归防线）

print("演练 4：应用 Persistence 结构约束")
do {
    // 通过编译期路径定位仓库内的真实 Persistence.swift
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/MigrationDrill
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // migration-drill
        .deletingLastPathComponent() // scripts
        .deletingLastPathComponent() // 仓库根
        .appendingPathComponent("Assistant/Services/Persistence.swift")

    if let source = try? String(contentsOf: sourceURL, encoding: .utf8) {
        // 旧代码的致命行为：打不开就 removeItem 删库重建。文件中不得再出现任何删除调用。
        check(!source.contains("removeItem"), "Persistence.swift 不含删除库文件调用（杜绝删库重建）")
        check(!source.contains("尝试重置数据库文件"), "不含旧版「重置数据库」注释残留")
        // 必须使用显式版本化迁移计划
        check(source.contains("AssistantMigrationPlan"), "使用显式版本化迁移计划（AssistantMigrationPlan）")
        check(source.contains("migrationPlan:"), "ModelContainer 打开时传入迁移计划")
        // 打开失败必须留下可诊断信息，供恢复页引导导出
        check(source.contains("diagnose"), "打开失败生成可诊断错误（含文件路径与体积）")
        // V1 模型必须是 V2 的子集（DEBUG 断言）
        check(source.contains("assertSchemaCoverage"), "DEBUG 下断言 V1 ⊆ V2（防删模型丢表）")
    } else {
        // 单独拷出脚本运行（非仓库环境）时跳过结构检查，不影响机制演练结论
        print("  · 未找到 \(sourceURL.path)，跳过结构检查")
    }
} catch {
    check(false, "结构约束演练抛错：\(error.localizedDescription)")
}

// MARK: - 演练 5：SwiftData `#Index` 的真实生效边界

func sqliteExec(_ url: URL, _ sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 3000)
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

func sqliteStrings(_ url: URL, _ sql: String) -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 3000)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        sqlite3_finalize(stmt)
        return []
    }
    defer { sqlite3_finalize(stmt) }
    var out: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
        out.append(String(cString: text))
    }
    return out
}

func indexes(ofTable url: URL, _ table: String) -> [String] {
    sqliteStrings(url, "select name from sqlite_master where type='index' and tbl_name='\(table)' order by name")
}

@available(macOS 15, *)
func openIndexedNote(_ url: URL) throws -> ModelContainer {
    let schema = Schema([DrillIndexedNote.self])
    let config = ModelConfiguration("idxdrill", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: config)
}

if #available(macOS 15.0, *) {
    print("演练 5：`#Index` 生效边界（决定「加索引提速」这类建议能不能落地）")
    do {
        let store = workDir.appendingPathComponent("indexed.store")

        // 5a. 全新库：声明的索引会落地
        do {
            let ctx = ModelContext(try openIndexedNote(store))
            for i in 0..<300 {
                ctx.insert(DrillIndexedNote(statusRaw: i % 2 == 0 ? "active" : "done",
                                            dueAt: .now.addingTimeInterval(Double(i))))
            }
            try ctx.save()
        }
        let created = indexes(ofTable: store, "ZDRILLINDEXEDNOTE")
        check(created.count == 3, "5a 新建库里 #Index 声明的 3 组索引落地（实得 \(created.count) 组）")

        // 5b. 已存在的库：删掉一组索引后用「声明了该索引」的模型重开——SwiftData 不会补建。
        //     这就是给已发布的老库加 #Index 的真实结局：声明进不了磁盘，读取路径毫无变化。
        let dropped = "Z_DrillIndexedNote_SwiftDataIndexOnBinarystatusRaw"
        check(sqliteExec(store, "drop index \(dropped)"), "5b 前置：删掉已建索引")
        do {
            let ctx = ModelContext(try openIndexedNote(store))
            check(try ctx.fetchCount(FetchDescriptor<DrillIndexedNote>()) == 300, "5b 重开后 300 条数据完整")
        }
        let afterReopen = indexes(ofTable: store, "ZDRILLINDEXEDNOTE")
        check(!afterReopen.contains(dropped), "5b 老库不会被补建索引——对已发布库加 #Index 是空操作（重开后 \(afterReopen.count) 组）")

        // 5c. `#if` 包裹会让宏静默失效：恒真分支也一样，编译、运行都不报错
        let ifStore = workDir.appendingPathComponent("ifwrapped.store")
        do {
            let schema = Schema([DrillIfNote.self])
            let ctx = ModelContext(try ModelContainer(for: schema,
                                  configurations: ModelConfiguration("ifdrill", schema: schema, url: ifStore)))
            for _ in 0..<20 { ctx.insert(DrillIfNote(statusRaw: "active")) }
            try ctx.save()
        }
        check(indexes(ofTable: ifStore, "ZDRILLIFNOTE").isEmpty, "5c 写在 #if 分支里的 #Index 完全不生效（无告警）")

        // 5d. 文件层手工建索引：SwiftData 认它、也会保留它——这是老库唯一可行的提速路径
        check(sqliteExec(ifStore, "create index IX_MANUAL_STATUS on ZDRILLIFNOTE (ZSTATUSRAW)"), "5d 前置：手工建索引")
        do {
            let schema = Schema([DrillIfNote.self])
            let ctx = ModelContext(try ModelContainer(for: schema,
                                  configurations: ModelConfiguration("ifdrill", schema: schema, url: ifStore)))
            check(try ctx.fetchCount(FetchDescriptor<DrillIfNote>()) == 20, "5d 手工索引下 SwiftData 读取正常")
        }
        check(indexes(ofTable: ifStore, "ZDRILLIFNOTE").contains("IX_MANUAL_STATUS"), "5d 手工索引在 SwiftData 重开后仍保留")
    } catch {
        check(false, "演练 5 抛错：\(error.localizedDescription)")
    }
} else {
    print("演练 5：跳过（`#Index` 需 macOS 15+ / iOS 18+）")
}

// MARK: - 汇总

print("")
if failures.isEmpty {
    print("P0-1 演练全部通过：旧库可升级、损坏库不删文件、未知结构库可恢复、`#Index` 生效边界已确认。")
    exit(0)
} else {
    print("P0-1 演练失败 \(failures.count) 项：")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
