import Foundation
import SwiftData

/// 人生大事任务 ↔ 首页镜像待办的完成态双向联动。
///
/// 软关联：`TodoItem.lifeEventTaskID` 指向 `LifeEventTask.id`（镜像创建时写入）。
/// 两边完成态变化时调用对应同步方法；无关联的待办/任务不受影响。
enum LifeEventTodoLink {
    /// 首页待办完成态变化后调用：把状态推给关联的人生大事任务（若有）。
    static func syncTask(for todo: TodoItem, in context: ModelContext) {
        guard let taskID = todo.lifeEventTaskID else { return }
        let descriptor = FetchDescriptor<LifeEventTask>(predicate: #Predicate { $0.id == taskID })
        guard let task = (try? context.fetch(descriptor))?.first else { return }
        let target = todo.status == .done ? "done" : "active"
        if task.statusRaw != target {
            task.statusRaw = target
        }
    }

    /// 人生大事任务完成态变化后调用：把状态推给全部镜像待办。
    static func syncMirrors(for task: LifeEventTask, in context: ModelContext) {
        let taskID = task.id
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.lifeEventTaskID == taskID })
        let mirrors = (try? context.fetch(descriptor)) ?? []
        let target: TodoStatus = task.isDone ? .done : .active
        for mirror in mirrors where mirror.status != target {
            mirror.status = target
        }
    }

    /// 项目级联删除时清掉镜像待办，避免首页留下孤儿。
    static func removeMirrors(taskIDs: [UUID], in context: ModelContext) {
        guard !taskIDs.isEmpty else { return }
        let idSet = Set(taskIDs)
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.lifeEventTaskID != nil })
        let mirrors = (try? context.fetch(descriptor)) ?? []
        for mirror in mirrors {
            if let linkedID = mirror.lifeEventTaskID, idSet.contains(linkedID) {
                TodoNotificationManager.shared.cancelNotification(for: mirror.id)
                context.delete(mirror)
            }
        }
    }
}
