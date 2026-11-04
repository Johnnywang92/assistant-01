import Foundation
import UIKit

/// 小助专属 `.assistant` 文件打包与解析服务
///
/// 支持原生 AirDrop 隔空投送、微信/文件 App 打开与导入
public enum AssistantPackageService {
    public static let fileExtension = "assistant"
    public static let mimeType = "application/x-assistant"
    public static let uti = "com.yifanwang.assistant01.package"

    /// 将通用信封包写入临时的 .assistant 文件，供 AirDrop 或系统分享菜单使用
    public static func createPackageFile(for envelope: UniversalShareEnvelope) -> URL? {
        guard let data = envelope.encode() else { return nil }

        // 清理文件名中不合法的文件名字符
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>| \n\t\r")
        let sanitizedTitle = envelope.title
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let fileName = (sanitizedTitle.isEmpty ? "小助离线数据包" : sanitizedTitle) + ".\(fileExtension)"

        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("Failed to write package file: \(error)")
            return nil
        }
    }

    /// 从文件 URL 读取并还原 UniversalShareEnvelope
    public static func readPackage(from fileURL: URL) -> UniversalShareEnvelope? {
        let isSecurityScoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UniversalShareEnvelope.decode(from: data)
    }
}
