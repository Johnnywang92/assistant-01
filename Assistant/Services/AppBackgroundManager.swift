import Foundation
import ImageIO
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

    public var displayName: String { L10n.tr(rawValue) }

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
        let raw: String = switch self {
        case .system: "随系统外观自动切换浅色/深色模式"
        case .aurora: "轻盈薄雾极光渐变，通透治愈"
        case .midnight: "深邃深蓝紫微光，沉稳优雅"
        case .sunset: "柔和暮光橙粉，温馨放松"
        case .mint: "清新自然薄荷绿意，舒缓双眼"
        case .paper: "典雅温润纸质底色，复古安静"
        case .pureDark: "极简深邃纯黑，OLED 屏幕省电护眼"
        case .customImage: "从本地相册导入心仪照片并调节模糊度"
        }
        return L10n.tr(raw)
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

/// 主题风格的 UserDefaults key；背景修饰器用 @AppStorage 只订阅此 key，而非整个 manager
public extension AppBackgroundStyle {
    static let defaultsKey = "app_background_style"
}

/// 全局背景主题管理器
@MainActor
public final class AppBackgroundManager: ObservableObject {
    public static let shared = AppBackgroundManager()

    private let styleKey = AppBackgroundStyle.defaultsKey
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
            scheduleBlurRefresh()
        }
    }

    @Published public var dimOpacity: Double {
        didSet {
            UserDefaults.standard.set(dimOpacity, forKey: dimKey)
        }
    }

    @Published public var customImage: UIImage? {
        didSet {
            scheduleBlurRefresh()
        }
    }

    /// 预渲染的模糊壁纸位图：视图层滚动时只贴静态图，不再每帧实时高斯
    @Published public private(set) var blurredWallpaper: UIImage?

    private var blurWorkItem: DispatchWorkItem?

    private let imageFileName = "custom_app_wallpaper.jpg"
    nonisolated private static let maxWallpaperPixelDimension: CGFloat = 1280
    nonisolated private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

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
        StartupMetrics.measure("bgManager.loadWallpaper") { loadCustomImage() }
    }

    /// 保存从相册挑选的照片到沙盒（自动降采样至适中尺寸，避免 4800 万像素巨幅图片导致内存飙升与 GPU 掉帧）
    public func saveCustomImage(_ image: UIImage) {
        let maxDimension = Self.maxWallpaperPixelDimension
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let resized: UIImage
        if max(pixelWidth, pixelHeight) > maxDimension {
            let scale = maxDimension / max(pixelWidth, pixelHeight)
            let newSize = CGSize(width: round(pixelWidth * scale), height: round(pixelHeight * scale))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            resized = image
        }

        guard let data = resized.jpegData(compressionQuality: 0.85) else { return }
        let url = getWallpaperFileURL()
        try? data.write(to: url)
        self.customImage = resized
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

    /// 备份导出：读取自定义壁纸文件字节（无自定义壁纸时返回 nil）
    public var customImageFileData: Data? {
        try? Data(contentsOf: getWallpaperFileURL())
    }

    /// 备份导入：写回自定义壁纸并按磁盘最新状态重载内存态
    public func restoreCustomImage(data: Data) {
        let url = getWallpaperFileURL()
        try? data.write(to: url)
        reloadFromDefaults()
    }

    /// 从 UserDefaults 与磁盘重载内存态（备份导入设置后调用，避免单例持有旧值）
    public func reloadFromDefaults() {
        currentStyleRaw = UserDefaults.standard.string(forKey: styleKey) ?? AppBackgroundStyle.system.rawValue
        blurRadius = UserDefaults.standard.object(forKey: blurKey) as? Double ?? 8.0
        dimOpacity = UserDefaults.standard.object(forKey: dimKey) as? Double ?? 0.25
        loadCustomImage()
    }

    private func loadCustomImage() {
        let url = getWallpaperFileURL()
        let data = StartupMetrics.measure("wallpaperRead") { try? Data(contentsOf: url) }
        guard let data else { return }
        let img = StartupMetrics.measure("wallpaperDecode(\(data.count / 1024)KB)") {
            Self.downsampledImage(from: data, maxPixelDimension: Self.maxWallpaperPixelDimension) ?? UIImage(data: data)
        }
        if let img {
            self.customImage = img
            // 若磁盘上残留旧版 3x 高清大图（> 600KB），后台静默写回降采样后的轻量文件，根治后续冷启动读盘与解码耗时
            if data.count > 600_000 {
                DispatchQueue.global(qos: .utility).async {
                    if let compact = img.jpegData(compressionQuality: 0.85), compact.count < data.count {
                        try? compact.write(to: url, options: .atomic)
                    }
                }
            }
        }
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelDimension)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    /// 选图/载入/拖动模糊度后，防抖 150ms 在后台一次性渲出模糊位图；
    /// 滚动期间视图只贴这张静态图，避免每个页面每帧做全屏实时高斯。
    private func scheduleBlurRefresh() {
        blurWorkItem?.cancel()
        guard let source = customImage, blurRadius > 0.5 else {
            blurredWallpaper = customImage
            return
        }
        // 按实际位图分辨率折算模糊像素半径（壁纸已降采样至 <=1280px，避免按 3x 放大半径拖慢高斯卷积）
        let maxPixelEdge = max(source.size.width * source.scale, source.size.height * source.scale)
        let effectiveScale = max(1.0, Double(maxPixelEdge) / 852.0)
        let pixelRadius = blurRadius * effectiveScale
        let work = DispatchWorkItem { [weak self, source, pixelRadius] in
            let blurred = StartupMetrics.measure("wallpaperBlur(radius \(Int(pixelRadius))px, \(source.size.width)x\(source.size.height))") {
                Self.gaussianBlurred(source, radius: pixelRadius) ?? source
            }
            DispatchQueue.main.async {
                StartupMetrics.mark("wallpaperBlur publish")
                self?.blurredWallpaper = blurred
            }
        }
        blurWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    nonisolated private static func gaussianBlurred(_ image: UIImage, radius: Double) -> UIImage? {
        guard radius > 0.5, let cgImage = image.cgImage else { return image }
        let input = CIImage(cgImage: cgImage).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let outCG = sharedCIContext.createCGImage(output.cropped(to: extent), from: extent) else { return image }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
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
                // 用户自选相册照片（模糊位图已预渲染，滚动时零实时高斯成本）
                if let uiImage = manager.blurredWallpaper ?? manager.customImage {
                    GeometryReader { geo in
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
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
        .responsiveAnimation(.easeInOut(duration: 0.3), value: manager.currentStyle)
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
/// 只订阅风格 key：调节模糊度/压暗度时不触发 content 子树重建
public struct ThemedBackgroundModifier: ViewModifier {
    @AppStorage(AppBackgroundStyle.defaultsKey) private var styleRaw = AppBackgroundStyle.system.rawValue

    public init() {}

    public func body(content: Content) -> some View {
        ZStack {
            if AppBackgroundStyle(rawValue: styleRaw) != .system {
                AppBackgroundView()
            }
            content
        }
    }
}

/// 列表卡片毛玻璃通透质感修饰器
/// 只订阅风格 key，不订阅 manager 的 blurRadius/dimOpacity 高频变动
public struct ThemedRowModifier: ViewModifier {
    @AppStorage(AppBackgroundStyle.defaultsKey) private var styleRaw = AppBackgroundStyle.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        if AppBackgroundStyle(rawValue: styleRaw) != .system {
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

/// 列表底色跟随主题，但只订阅风格 key（替代页面对整个 bgManager 的 @ObservedObject 订阅）
public struct ThemedScrollContentBackgroundModifier: ViewModifier {
    @AppStorage(AppBackgroundStyle.defaultsKey) private var styleRaw = AppBackgroundStyle.system.rawValue

    public init() {}

    public func body(content: Content) -> some View {
        let isCustom = AppBackgroundStyle(rawValue: styleRaw) != .system
        content.scrollContentBackground(isCustom ? .hidden : .automatic)
    }
}

/// 页面底色跟随主题：自定义主题时透出壁纸层，系统风格时用给定底色
public struct ThemedPageBackgroundModifier: ViewModifier {
    @AppStorage(AppBackgroundStyle.defaultsKey) private var styleRaw = AppBackgroundStyle.system.rawValue
    private let baseColor: Color

    public init(baseColor: Color) {
        self.baseColor = baseColor
    }

    public func body(content: Content) -> some View {
        content.background(AppBackgroundStyle(rawValue: styleRaw) != .system ? Color.clear : baseColor)
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

    /// 列表滚动底色跟随主题（只订阅风格 key）
    func themedScrollContentBackground() -> some View {
        modifier(ThemedScrollContentBackgroundModifier())
    }

    /// 页面底色跟随主题（只订阅风格 key）
    func themedPageBackground(_ baseColor: Color = Color(.systemGroupedBackground)) -> some View {
        modifier(ThemedPageBackgroundModifier(baseColor: baseColor))
    }
}

