**简体中文** | [English](README.en.md)

# 小助（Assistant）

一款完全运行在 iPhone 本地的离线生活助理 App，围绕「待办、记账、快递取件、证件保险箱、语音对话」等高频场景，串联成免掏手机的生活闭环。所有数据只存本机，支持端侧语音识别与本地 LLM 推理（可选），并通过灵动岛实时活动、桌面/锁屏小组件与 Apple Watch 智能叠放打通腕上操作。

- 平台：iOS 18.0+，仅竖屏（iPhone）
- 界面语言：简体中文 / English（`zh-Hans` 为开发语言）
- 签名：免费个人团队（Personal Team），签名有效期 7 天，可用脚本自动续签

## 核心功能

| 模块 | 说明 |
| --- | --- |
| 待办中心 | 分类待办、逾期分诊、重复规则、完成历史、通知排期与稍后提醒 |
| 语音助手 | 悬浮语音球长按直接对话，离线 ASR 转写 + 统一意图处理器路由到各模块 |
| Omnibox 单入口速记 | 文字/语音/截图多模态输入，自动分流生成待办、账目、物品档案 |
| 一句话记账 | 口语化金额解析（同音词归一化、中文数字）、预算与「今日安心花」动态额度、周期性支出自动入账 |
| 快递与出门场景 | 地理围栏到达提醒、取件码上灵动岛/锁屏/手表，抬腕点「已取件」即销号 |
| 生活档案 | 证件保险箱（Face ID 保护）、密码库（加密存储）、物品收纳与日均持有成本、车辆/宠物/孩子/纪念日/生活事件管理 |
| 习惯与服药 | 周期性习惯打卡、服药日程评估与提醒 |
| 情景智能 | 常驻地点自主学习、每日痛点巡检（低电量、证件临期、自动续费防扣款）、定期复盘报告 |
| 模型管理 | 本地 GGUF 模型下载与管理，也支持连接局域网 Ollama |
| 系统整合 | App Shortcuts、操作按钮、敲击背面、桌面交互式小组件、Live Activities、小组件直接完成待办 |
| 数据安全 | 全量备份/还原（PIN 加密导出导入）、App 锁屏密码、长辈模式、可自定义 Tab 栏与 App 背景 |

## 技术栈

- **SwiftUI + SwiftData**：全部 UI 与持久化，SwiftData 采用版本化迁移计划，迁移失败时保留原库并提供恢复/导出入口（见 `Assistant/Services/Persistence.swift`）
- **ActivityKit / WidgetKit / AppIntents**：灵动岛实时活动、交互式小组件与系统快捷指令，主 App 与扩展通过 App Group（`group.com.yifanwang.assistant01`）共享快照与指令队列
- **Speech / AVFoundation**：离线语音识别与录音转写
- **LlamaSwift**（外部 SPM 包）：端侧 LLM 推理运行时
- **AssistantCore**（本地 SPM 包）：规则解析、快递匹配等纯逻辑下沉于此，可独立测试
- **XcodeProj**：工程文件由 `xcodegen` 从 `project.yml` 生成，不手动维护 `.xcodeproj`

## 目录结构

```
Assistant/                # 主 App target
├── App/                  # 入口（AssistantApp.swift）、生命周期与前台巡检调度
├── Features/             # 各功能页面（待办、记账、保险箱、语音对话、Omnibox 等）
├── Models/               # SwiftData 模型
├── Services/             # 业务服务（通知、迁移、定位、推理、备份等）
└── Intents/              # AppIntents / 快捷指令
AssistantWidgetExtension/ # 小组件与 Live Activity 扩展
WidgetShared/             # 主 App 与扩展共享的快照模型与 Intent
Packages/AssistantCore/   # 本地 SPM 包：纯逻辑 + 单元测试
scripts/                  # 编译安装、签名续签等脚本
project.yml               # xcodegen 工程定义（唯一工程来源）
todo.md                   # 项目改进清单与实施记录
```

## 构建与运行

前置：macOS + Xcode 16+，`brew install xcodegen`。

```bash
# 1. 生成 Xcode 工程（project.yml 是唯一来源，重新生成即可）
xcodegen generate

# 2. 用 Xcode 打开 Assistant.xcodeproj，选择 Assistant scheme 运行
```

### 真机安装与 7 天续签（免费账号）

```bash
cp scripts/config.example scripts/config.local   # 填写 DEVELOPMENT_TEAM、BUNDLE_ID、DEVICE_ID
scripts/reinstall.sh                              # 编译 Release 并安装到 iPhone
scripts/install_auto_renew_agent.sh               # 安装自动续签 Agent（每 < 7 天自动重装一次）
```

## 测试

纯逻辑测试位于 `Packages/AssistantCore/Tests/`：

```bash
cd Packages/AssistantCore && swift test
```

## 隐私说明

- 待办、账目、证件、密码等数据只保存在设备本地，备份文件为 PIN 加密导出。
- 默认端侧语音识别与规则处理不联网；仅当手动启用局域网 Ollama 远程推理时，才会向所配置的端点发送对话上下文。
- 权限（通知、定位、麦克风、相册、Face ID 等）按需申请，可在系统设置中随时关闭。
