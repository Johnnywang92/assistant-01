import Foundation
import SwiftUI
import UIKit

/// App 视觉背景风格枚举
public enum AppBackgroundStyle: String, CaseIterable, Identifiable {
    case system = "系统默认"         // 遵循原生深浅色
    case aurora = "极光晨曦"         // 柔和微光蓝紫粉，治愈通透
    case midnight = "暗夜星空"       // 幽邃蓝黑星空调，极客沉浸
    case sunset = "暮光暖阳"         // 温暖暮色橙粉，惬意舒适
    case mint = "薄荷微风"           // 清爽草木淡绿，轻盈护眼
    case paper = "羊皮书卷"           // 温暖低饱和度米白纸感
    case pureDark = "纯黑极简"       // OLED 纯黑省电模式
    case customImage = "自选壁纸"     // 从相册选取自定义照片

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .aurora: return "sparkles"
        case .midnight: return "moon.stars.fill"
        case .sunset: return "sun.horizon.fill"
        case .mint: return "leaf.fill"
        case .paper: return "doc.plaintext.fill"
        case .pureDark: return "circle.fill"
        case .customImage: return "photo.fill"
        }
    }

    public var description: String {
        switch self {
        case .system: return "随系统外观自动切换浅色/深色模式"
        case .aurora: return "轻盈薄雾极光渐变，通透治愈"
        case .midnight: return "深邃深蓝紫微光，沉稳优雅"
        case .sunset: return "柔和暮光橙粉，温馨放松"
        case .mint: return "清新自然薄荷绿意，舒缓双眼"
        case .paper: return "典雅温润纸质底色，复古安静"
        case .pureDark: return "极简深邃纯黑，OLED 屏幕省电护眼"
        case .customImage: return "从本地相册导入心仪照片并调节模糊度"
        }
    }

    /// 针对特定极黑或暗夜主题推荐适用的系统色彩方案
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .pureDark, .midnight:
            return .dark
        default:
            return nil
        }
    }
}

/// 全局背景主题管理器
@MainActor
public final class AppBackgroundManager: ObservableObject {
    public static let shared = AppBackgroundManager()

    private let styleKey = "app_background_style"
    private let blurKey = "app_background_blur"
    private let dimKey = "app_background_dim"

    @Published public var currentStyleRaw: String {
        didSet {
            UserDefaults.standard.set(currentStyleRaw, forKey: styleKey)
        }
    }

    @Published public var blurRadius: Double {
        didSet {
            UserDefaults.standard.set(blurRadius, forKey: blurKey)
        }
    }

    @Published public var dimOpacity: Double {
        didSet {
            UserDefaults.standard.set(dimOpacity, forKey: dimKey)
        }
    }

    @Published public var customImage: UIImage?

    private let imageFileName = "custom_app_wallpaper.jpg"

    public var currentStyle: AppBackgroundStyle {
        get { AppBackgroundStyle(rawValue: currentStyleRaw) ?? .system }
        set {
            currentStyleRaw = newValue.rawValue
        }
    }

    public var isCustomBackgroundActive: Bool {
        currentStyle != .system
    }

    private init() {
        self.currentStyleRaw = UserDefaults.standard.string(forKey: styleKey) ?? AppBackgroundStyle.system.rawValue
        self.blurRadius = UserDefaults.standard.object(forKey: blurKey) as? Double ?? 8.0
        self.dimOpacity = UserDefaults.standard.object(forKey: dimKey) as? Double ?? 0.25
        loadCustomImage()
    }

    /// 保存从相册挑选的照片到沙盒
    public func saveCustomImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let url = getWallpaperFileURL()
        try? data.write(to: url)
        self.customImage = image
        self.currentStyle = .customImage
        Haptic.success()
    }

    /// 清理自定义壁纸
    public func removeCustomImage() {
        let url = getWallpaperFileURL()
        try? FileManager.default.removeItem(at: url)
        self.customImage = nil
        if currentStyle == .customImage {
            self.currentStyle = .system
        }
    }

    private func loadCustomImage() {
        let url = getWallpaperFileURL()
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            self.customImage = img
        }
    }

    private func getWallpaperFileURL() -> URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0]
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(imageFileName)
    }
}

/// 全局背景渲染视图
public struct AppBackgroundView: View {
    @ObservedObject private var manager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        ZStack {
            switch manager.currentStyle {
            case .system:
                Color(.systemGroupedBackground)

            case .aurora:
                // 极光晨曦渐变
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(hex: "0D1B2A"), Color(hex: "1B263B"), Color(hex: "2E1C3B")]
                        : [Color(hex: "E0F2FE"), Color(hex: "F3E8FF"), Color(hex: "FCE7F3")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

            case .midnight:
                // 暗夜星空
                LinearGradient(
                    colors: [
                        Color(hex: "080B12"),
                        Color(hex: "0F172A"),
                        Color(hex: "1E1B4B")
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .sunset:
                // 暮光暖阳
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(hex: "2A1810"), Color(hex: "2B1B2A"), Color(hex: "171926")]
                        : [Color(hex: "FFF7ED"), Color(hex: "FEE2E2"), Color(hex: "EDE9FE")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

            case .mint:
                // 薄荷微风
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(hex: "0D201A"), Color(hex: "112922"), Color(hex: "0A1713")]
                        : [Color(hex: "F0FDF4"), Color(hex: "ECFDF5"), Color(hex: "E0F2FE")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

            case .paper:
                // 羊皮书卷纸感
                if colorScheme == .dark {
                    Color(hex: "181816")
                } else {
                    Color(hex: "F8F6F0")
                }

            case .pureDark:
                // OLED 纯黑
                Color.black

            case .customImage:
                // 用户自选相册照片
                if let uiImage = manager.customImage {
                    GeometryReader { geo in
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: manager.blurRadius)
                            .overlay(
                                Color.black.opacity(manager.dimOpacity)
                            )
                    }
                } else {
                    Color(.systemGroupedBackground)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: manager.currentStyle)
    }
}

// MARK: - Color Hex 拓展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - 主题全局背景与列表卡片透光修饰器

/// 全局主题背景修饰器（当激活自定主题时，在底层渲染全屏高质感背景）
public struct ThemedBackgroundModifier: ViewModifier {
    @ObservedObject private var manager = AppBackgroundManager.shared

    public init() {}

    public func body(content: Content) -> some View {
        ZStack {
            if manager.isCustomBackgroundActive {
                AppBackgroundView()
            }
            content
        }
    }
}

/// 列表卡片毛玻璃通透质感修饰器
public struct ThemedRowModifier: ViewModifier {
    @ObservedObject private var manager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        if manager.isCustomBackgroundActive {
            content
                .listRowBackground(
                    Color(.secondarySystemGroupedBackground)
                        .opacity(colorScheme == .dark ? 0.72 : 0.85)
                )
        } else {
            content
        }
    }
}

public extension View {
    /// 挂载全局主题背景底色层
    func themedAppBackground() -> some View {
        modifier(ThemedBackgroundModifier())
    }

    /// 应用主题磨砂半透明行背景
    func themedRow() -> some View {
        modifier(ThemedRowModifier())
    }
}

