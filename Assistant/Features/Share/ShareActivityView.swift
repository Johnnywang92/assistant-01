/// 系统 UIActivityViewController 桥接封装
///
/// 从 TodoShareSheet.swift 拆出：纯 UIKit 桥接，无业务逻辑。
import AssistantCore
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 系统 UIActivityViewController 桥接封装
struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
