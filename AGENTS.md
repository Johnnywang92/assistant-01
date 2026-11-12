# 项目开发与防编译报错规范 (Project Agent Guidelines)

本文档为 Antigravity Agent 在本项目的核心记忆与代码审查规则。每次修改代码、重构或交付前必须严格遵守：

## 1. 属性名与方法签名必须精准对齐（严禁凭记忆猜测）
* **查证先于调用**：在 SwiftUI View、Service 或 ViewModel 中引用任何 Model / Struct / Enum 的属性或方法前，必须通过读取定义文件或 `git grep` 确认准确命名，严禁凭直觉或相近英文词猜测（例如：`ItemCostSummary` 中的字段是 `daysHeld` 而非 `holdingDays`）。
* **全局联动排查**：一旦修改或移动了某个公共类型中的字段、方法名或构造函数，必须立即执行全局搜索（`git grep "<旧名称>"`），确保所有相关调用方同步更新。

## 2. 变更模型字段时必须提供向后兼容别名
* **兼容别名原则**：若因业务需求必须更名 Struct/Class 属性，须在原模型中保留计算属性别名转发（例如 `public var holdingDays: Int { daysHeld }`），避免因历史卡片、Widget、Watch 端或测试用例未同步更新而导致突发编译失败。

## 3. 代码修改后必跑语法与类型解析自检
* **本地轻量级语法解析**：每次完成代码编辑后，必须对所有修改过的 `.swift` 文件执行：
  ```bash
  swiftc -parse <ModifiedFile1.swift> <ModifiedFile2.swift> ...
  ```
  确保零语法错误、零括号遗漏或格式瑕疵后，方可向用户交付或汇报。

## 4. 食物与多模态体系关键约束
* **大模型推断与食物库解耦**：端侧 Qwen3-VL 或 LLM 识别出未知菜品时，不得因未在静态 `FoodCatalog` 收录而直接抛弃，必须通过 `FoodItem.inferred` 动态构建推断条目。
* **餐盘模式与多菜录入**：用户连续录入多道食物时，必须追加至当前餐盘组合中，统一按“一餐多菜”入账，不得把每一个菜品独立计为一餐。

