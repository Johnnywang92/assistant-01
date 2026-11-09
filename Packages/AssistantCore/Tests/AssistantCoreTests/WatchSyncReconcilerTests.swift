import XCTest
@testable import AssistantCore

final class WatchSyncReconcilerTests: XCTestCase {

    func testOptimisticCompleteRemovesFromTodosAndParcels() {
        let parcelID = UUID()
        let todoID = UUID()
        var snapshot = WidgetSnapshot(
            topTodos: [
                WidgetTodoEntry(id: todoID, title: "写周报", typeRaw: "task"),
                WidgetTodoEntry(id: parcelID, title: "取件", typeRaw: "parcel", pickupCode: "3-2-104")
            ],
            parcels: [
                WidgetTodoEntry(id: parcelID, title: "取件", typeRaw: "parcel", pickupCode: "3-2-104")
            ],
            todayExpense: 25,
            generatedAt: Date(timeIntervalSince1970: 1000)
        )

        WatchSyncReconciler.applyOptimistically(.completeTodo(parcelID), to: &snapshot)

        XCTAssertEqual(snapshot.topTodos.map(\.id), [todoID])
        XCTAssertTrue(snapshot.parcels.isEmpty)
    }

    func testReconcileDropsAckedCommandsAndReplaysUnacked() {
        let todo1 = UUID()
        let todo2 = UUID()
        let cmd1ID = UUID()
        let cmd2ID = UUID()

        let localBase = WidgetSnapshot(
            topTodos: [
                WidgetTodoEntry(id: todo1, title: "事项1", typeRaw: "task"),
                WidgetTodoEntry(id: todo2, title: "事项2", typeRaw: "task")
            ],
            parcels: [],
            todayExpense: 10,
            generatedAt: Date(timeIntervalSince1970: 1000)
        )

        // 远端新快照：已确认 cmd1（事项1 已从 topTodos 移除），但还没收到 cmd2（补水 +250ml）
        let remote = WidgetSnapshot(
            topTodos: [
                WidgetTodoEntry(id: todo2, title: "事项2", typeRaw: "task")
            ],
            parcels: [],
            todayExpense: 10,
            todayWaterML: 500,
            waterGoalML: 1700,
            ackedCommandIDs: [cmd1ID],
            generatedAt: Date(timeIntervalSince1970: 2000)
        )

        let pending = [
            WatchCommandEnvelope(id: cmd1ID, command: .completeTodo(todo1)),
            WatchCommandEnvelope(id: cmd2ID, command: .addWater(beverageRaw: "plain_water", volumeML: 250))
        ]

        let result = WatchSyncReconciler.reconcile(
            remoteSnapshot: remote,
            localBaseSnapshot: localBase,
            pendingEnvelopes: pending
        )

        XCTAssertEqual(result.remainingPending.map(\.id), [cmd2ID])
        XCTAssertEqual(result.baseSnapshot.todayWaterML, 500)
        // 未确认的 cmd2 (+250ml) 被自动重放到展示快照上
        XCTAssertEqual(result.displaySnapshot.todayWaterML, 750)
    }

    func testReconcileIgnoresStaleRemoteSnapshot() {
        let newerLocal = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 88,
            generatedAt: Date(timeIntervalSince1970: 3000)
        )
        let olderRemote = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 12,
            generatedAt: Date(timeIntervalSince1970: 1500)
        )

        let result = WatchSyncReconciler.reconcile(
            remoteSnapshot: olderRemote,
            localBaseSnapshot: newerLocal,
            pendingEnvelopes: []
        )

        XCTAssertEqual(result.baseSnapshot.todayExpense, 88)
        XCTAssertEqual(result.displaySnapshot.todayExpense, 88)
    }

    func testBackwardCompatibleSnapshotDecoding() throws {
        // 旧版 JSON（不含 todayWaterML / waterGoalML / todayMood / ackedCommandIDs）也能平滑解码
        let legacyJSON = """
        {
          "topTodos": [],
          "parcels": [],
          "todayExpense": 42.5,
          "generatedAt": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.todayExpense, 42.5)
        XCTAssertEqual(decoded.todayWaterML, 0)
        XCTAssertEqual(decoded.waterGoalML, 1700)
        XCTAssertNil(decoded.todayMood)
        XCTAssertTrue(decoded.ackedCommandIDs.isEmpty)
    }

    func testStalePendingCountDetection() {
        let now = Date(timeIntervalSince1970: 100_000)
        let fresh = WatchCommandEnvelope(
            command: .addWater(beverageRaw: "plain_water", volumeML: 150),
            createdAt: now.addingTimeInterval(-3600)
        )
        let stale = WatchCommandEnvelope(
            command: .logMood(mood: 4, energy: 4, stress: 2),
            createdAt: now.addingTimeInterval(-25 * 3600)
        )

        let count = WatchSyncReconciler.stalePendingCount(in: [fresh, stale], now: now)
        XCTAssertEqual(count, 1)
    }
}
