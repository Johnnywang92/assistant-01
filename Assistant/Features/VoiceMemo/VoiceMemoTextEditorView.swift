import AssistantCore
import SwiftData
import SwiftUI

/// 纯文字备忘的编辑页。
///
/// 与语音备忘共用同一个 `VoiceMemo` 模型、详情页、分享卡与备份链路，
/// 只是没有音频：`audioFileName` 为空串、`isTextOnly = true`、`segments` 为空。
/// 之后想补录音时走「补录一段」，仍落在这一条备忘里，不会多出一条记录。
struct VoiceMemoTextEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建；非 nil = 编辑已有文字备忘。
    let memo: VoiceMemo?

    @State private var title = ""
    @State private var bodyText = ""
    @State private var tag: VoiceMemoTag = .inspiration
    /// 进页面时的标题原文，用来判断用户是否真的动过标题。
    /// 不记录的话，「打开一条已存在的备忘、不碰标题、直接保存」会被误判成手写标题。
    @State private var originalTitle = ""
    @State private var saveError: String?
    @State private var alertTitle = "保存失败"
    /// 「保存并生成分享图」：先落库，再把分享面板挂在本页上方。
    /// 关闭分享面板后才收起编辑页，避免同一个页面同时 present 两个 sheet。
    @State private var shareTarget: VoiceMemo?
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("标题") {
                    TextField("给它起个标题", text: $title)
                        .font(.headline)
                }

                Section("分类") {
                    Picker("分类", selection: $tag) {
                        ForEach(VoiceMemoTag.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("正文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                        .font(.callout)
                }

                Section {
                    // 显性主入口，不藏进菜单：写完就能出图，不必先回列表再点开详情。
                    Button {
                        commit(andShare: true)
                    } label: {
                        Label("保存并生成分享图", systemImage: "photo.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                Color.red.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("保存并生成分享图")

                    Text("内容只存在本机。也可以先保存，之后从详情页点「生成分享图」；卡片样式、四套主题与水印和语音笔记共用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .themedScrollContentBackground()
            .themedAppBackground()
            .navigationTitle(memo == nil ? "新建文字备忘" : "编辑文字备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit() }.bold()
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showShareSheet, onDismiss: { dismiss() }) {
                if let shareTarget {
                    VoiceMemoShareSheet(memo: shareTarget)
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func load() {
        guard let memo else { return }
        // 读 displayTitle：旧数据里纯文字备忘却存着「语音备忘 <时间>」，
        // 加载时就用纠正后的标题，避免一进页面又看到错文案。
        title = memo.displayTitle
        originalTitle = memo.displayTitle
        tag = memo.tag
        bodyText = memo.transcription ?? memo.document.plainText
    }

    private func commit(andShare: Bool = false) {
        // 空内容不该产出一张「暂无可分享的内容」的卡片。
        if andShare && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alertTitle = "还没有内容"
            saveError = "先写点正文，再生成分享图。"
            Haptic.warning()
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题留空时先用正文首句兜底（与语音备忘转写完后自动起标题同一套规则），
        // 正文也起不出标题才退回「文字备忘 11月8日 20:15」。
        // 旧实现一律用 `VoiceMemo.defaultTitle()`，于是纯文字备忘被叫成「语音备忘」。
        let finalTitle = trimmedTitle.isEmpty
            ? (VoiceMemoTextAnalyzer.suggestedTitle(from: bodyText)
               ?? VoiceMemo.defaultTitle(isTextOnly: true))
            : trimmedTitle

        let target: VoiceMemo
        if let memo {
            target = memo
            target.title = finalTitle
            target.tag = tag
        } else {
            let newMemo = VoiceMemo(title: finalTitle, duration: 0, audioFileName: "", tag: tag)
            newMemo.isTextOnly = true
            context.insert(newMemo)
            target = newMemo
        }
        // 只有用户真的改过标题才锁定它；没动过就保留自动标题的能力，
        // 清空标题等于把命名权交还给自动标题。
        let titleChanged = trimmedTitle != originalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            target.titleIsUserEdited = false
        } else if titleChanged {
            target.titleIsUserEdited = true
        }

        // 正文同时写进结构化块与 transcription 全文：
        // 全局搜索、分享文字、备份导出都还在读后者。
        let document = MemoBlockBuilder.build(from: bodyText, title: finalTitle)
        target.apply(document: document)

        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存文字备忘") }) else {
            Haptic.error()
            alertTitle = "保存失败"
            saveError = "保存失败，内容仍保留在页面上，可以重试。"
            return
        }
        Haptic.success()
        if andShare {
            // 先把备忘落库再挂分享面板：面板会写卡片标题设置，需要真实的 ModelContext 对象。
            shareTarget = target
            showShareSheet = true
        } else {
            dismiss()
        }
    }
}
