import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

struct HomeGreetingCard: View {
    let activeCount: Int
    @State private var weatherSymbol = "cloud.sun.fill"
    @State private var weatherText = "天气稍后更新"
    @State private var isLoadingWeather = true
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @ObservedObject private var locationService = LocationReminderService.shared

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        case 18..<24: return "晚上好"
        default: return "夜深了"
        }
    }

    private var statusText: String {
        if activeCount == 0 { return "现在没有什么着急的事需要处理，可以放松一下" }
        if activeCount == 1 { return "今天还有 1 件事，按自己的节奏处理就好" }
        return "今天还有 \(activeCount) 件事，先处理最重要的一件就好"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(greeting)，\(userTitle.isEmpty || userTitle == "你" ? "朋友" : userTitle)")
                    .font(.headline.weight(.semibold))
                Text(L10n.tr(statusText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Haptic.light()
                Task { await loadWeather(force: true, requestPermission: true) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: weatherSymbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text(weatherText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .task { await loadWeather() }
        .onChange(of: locationService.authorizationStatus) { _, _ in
            Task { await loadWeather(force: true) }
        }
    }

    @MainActor
    private func loadWeather(force: Bool = false, requestPermission: Bool = false) async {
        guard force || isLoadingWeather else { return }

        if let cached = WeatherAlertService.shared.cachedWeatherSnapshot, weatherText == "天气稍后更新" {
            weatherSymbol = cached.symbolName
            weatherText = "\(cached.conditionDescription) \(cached.formattedTemperature)"
        }

        var location = locationService.lastKnownLocation
        if location == nil {
            _ = await locationService.requestSingleLocationSample(requestPermissionIfNeeded: requestPermission)
            location = locationService.lastKnownLocation
        }
        guard let location else {
            if let cached = WeatherAlertService.shared.cachedWeatherSnapshot {
                weatherSymbol = cached.symbolName
                weatherText = "\(cached.conditionDescription) \(cached.formattedTemperature)"
            } else {
                weatherText = locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted
                    ? "请开启定位"
                    : "点击获取天气"
            }
            isLoadingWeather = false
            return
        }
        isLoadingWeather = true
        if let snapshot = await WeatherAlertService.shared.fetchCurrentWeather(for: location) {
            weatherSymbol = snapshot.symbolName
            weatherText = "\(snapshot.conditionDescription) \(snapshot.formattedTemperature)"
        } else {
            weatherText = "天气不可用"
        }
        isLoadingWeather = false
    }
}

/// 首页顶部卡片分页：欢迎信息与万能投喂口可以左右滑动，减少固定入口对待办列表的占用。
struct HomeTopCardsCarousel: View {
    let activeCount: Int
    let onOpenOmnibox: () -> Void

    var body: some View {
        TabView {
            HomeGreetingCard(activeCount: activeCount)
                .tag(0)

            OmniboxEntryCard(onOpen: onOpenOmnibox)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: 100)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("首页快捷卡片，可左右滑动"))
    }
}

/// 首页入口卡：万能投喂口（文字 / 小票截图丢进来，自动记账、建待办、存收集箱）
struct OmniboxEntryCard: View {
    var onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.purple))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("万能投喂口"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("丢进文字、小票截图，自动记账、建待办、存收集箱"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TodoCategoryCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [TodoFilterCategory]
    let onSave: ([TodoFilterCategory]) -> Void

    init(categories: [TodoFilterCategory], onSave: @escaping ([TodoFilterCategory]) -> Void) {
        self._categories = State(initialValue: categories)
        self.onSave = onSave
    }

    private var hiddenCategories: [TodoFilterCategory] {
        TodoFilterCategory.allCases.filter { !categories.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("首页显示顺序") {
                    ForEach(categories) { category in
                        HStack(spacing: 10) {
                            Image(systemName: categoryIcon(category))
                                .foregroundStyle(categoryColor(category))
                                .frame(width: 24)
                            Text(L10n.tr(category.rawValue))
                            Spacer()
                            if category == .all {
                                Text("固定")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        categories.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        categories.remove(atOffsets: offsets)
                        if !categories.contains(.all) { categories.insert(.all, at: 0) }
                    }
                }

                if !hiddenCategories.isEmpty {
                    Section("添加分类") {
                        ForEach(hiddenCategories) { category in
                            Button {
                                categories.append(category)
                            } label: {
                                Label(L10n.tr(category.rawValue), systemImage: categoryIcon(category))
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("定制首页分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(categories)
                        dismiss()
                    }
                }
            }
        }
    }

    private func categoryIcon(_ category: TodoFilterCategory) -> String {
        switch category {
        case .all: return "square.grid.2x2.fill"
        case .general: return "calendar"
        case .work: return "briefcase.fill"
        case .recurring: return "repeat"
        case .parcel: return "shippingbox.fill"
        case .life: return "heart.fill"
        case .alert: return "exclamationmark.triangle.fill"
        case .parenting: return "figure.and.child.holdinghands"
        case .pet: return "pawprint.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    private func categoryColor(_ category: TodoFilterCategory) -> Color {
        switch category {
        case .all: return .secondary
        case .general: return .blue
        case .work: return .brown
        case .recurring: return .indigo
        case .parcel: return .orange
        case .life: return .green
        case .alert: return .red
        case .parenting: return .pink
        case .pet: return .orange
        case .other: return .secondary
        }
    }
}
