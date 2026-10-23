import CoreLocation
import SwiftData
import SwiftUI

/// 常用地点管理与自学习可视化视图
struct LearnedPlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LearnedPlace.visitCount, order: .reverse) private var places: [LearnedPlace]
    @Query private var samples: [LocationStaySample]
    @ObservedObject private var locationService = LocationReminderService.shared

    @State private var showingAddPlaceSheet = false
    @State private var isSampling = false
    @State private var isRefreshingPlaces = false
    @State private var sampleResultMessage: String?
    @AppStorage("learnedPlacesEnabled") private var learnedPlacesEnabled = true

    var body: some View {
        List {
            // MARK: - 诊断与状态看板
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "brain.head.profile")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("时空画像自主学习引擎")
                                .font(.headline)
                            Text("驻留时段聚类 + 真实路名反查 + 端侧 AI 角色推断")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 指标看板
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("常用地点")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(places.count) 处")
                                .font(.subheadline.bold())
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("累积时空样本")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(samples.count) 次")
                                .font(.subheadline.bold())
                                .foregroundStyle(samples.count >= 3 ? Color.green : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("定位权限状态")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(L10n.tr(authStatusTitle))
                                .font(.subheadline.bold())
                                .foregroundStyle(isLocationAuthorized ? Color.green : Color.red)
                        }
                    }

                    Toggle("启用常用地点感知", isOn: $learnedPlacesEnabled)
                        .font(.subheadline)
                        .onChange(of: learnedPlacesEnabled) { _, enabled in
                            if !enabled {
                                sampleResultMessage = "常用地点感知已关闭，不再自动采样或匹配当前地点。"
                            } else {
                                sampleResultMessage = "常用地点感知已开启。"
                            }
                        }

                    // 权限未就绪时的提示与跳转
                    if !isLocationAuthorized {
                        Button {
                            if locationService.authorizationStatus == .notDetermined {
                                locationService.requestWhenInUseAuthorization()
                            } else {
                                locationService.openSystemSettings()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(locationService.authorizationStatus == .notDetermined ? "点击授予「使用期间定位」权限" : "前往系统「设置」开启定位权限")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.bold())
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                            .foregroundStyle(Color.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    // 立即记录当前位置采样按钮
                    Button {
                        sampleCurrentLocation()
                    } label: {
                        HStack {
                            if isSampling {
                                ProgressView()
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "location.fill")
                            }
                            Text(isSampling ? "正在获取当前 GPS 坐标并采样..." : "📍 立即记录当前位置为驻留样本")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                        .foregroundStyle(.white)
                    }
                    .disabled(isSampling || !isLocationAuthorized || !learnedPlacesEnabled)
                    .buttonStyle(.plain)

                    // 智能重新聚类与地名解析按钮
                    if !places.isEmpty {
                        Button {
                            reclusterAndEnrichAllPlaces(useAI: true)
                        } label: {
                            HStack(spacing: 6) {
                                if isRefreshingPlaces {
                                    ProgressView().controlSize(.small)
                                    Text("正在合并漂移点并解析真实地名与角色…")
                                } else {
                                    Image(systemName: "sparkles")
                                    Text("智能合并漂移点并推断「家 / 公司」真实地名")
                                }
                                Spacer()
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.12)))
                            .foregroundStyle(.purple)
                        }
                        .disabled(isRefreshingPlaces || !learnedPlacesEnabled)
                        .buttonStyle(.plain)
                    }

                    if let msg = sampleResultMessage {
                        Text(L10n.tr(msg))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("学习规则：相距 300 米内的漂移点自动合并并解析街道/商圈名称；只有深夜清晨长期停留才会识别为「家」，只有工作日白天长期停留才会识别为「公司」，其他地点保留为待确认地点。")
            }

            // MARK: - 地点列表
            Section("已记录的地点") {
                if places.isEmpty {
                    ContentUnavailableView(
                        "暂未记录常用地点",
                        systemImage: "building.2.slash",
                        description: Text("当前累积样本较少（\(samples.count)/3）。你可以点击上方的「立即记录当前位置为驻留样本」，或点击右上角「+」直接将当前位置标记为公司。")
                    )
                } else {
                    ForEach(places) { place in
                        NavigationLink {
                            LearnedPlaceDetailView(place: place)
                        } label: {
                            PlaceRow(place: place)
                        }
                    }
                    .onDelete(perform: deletePlaces)
                }
            }
        }
        .navigationTitle("常用地点")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddPlaceSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPlaceSheet) {
            AddPlaceSheet()
        }
        .task {
            await PlaceLearningEngine(context: context).refreshAndDeduplicateAllPlaces(useAI: false)
        }
    }

    private var isLocationAuthorized: Bool {
        locationService.authorizationStatus == .authorizedWhenInUse ||
        locationService.authorizationStatus == .authorizedAlways
    }

    private var authStatusTitle: String {
        switch locationService.authorizationStatus {
        case .authorizedAlways: return "始终允许"
        case .authorizedWhenInUse: return "使用期间"
        case .denied, .restricted: return "未授权"
        case .notDetermined: return "待授权"
        @unknown default: return "未知"
        }
    }

    private func reclusterAndEnrichAllPlaces(useAI: Bool) {
        guard !isRefreshingPlaces else { return }
        isRefreshingPlaces = true
        sampleResultMessage = nil
        Haptic.light()
        Task {
            let engine = PlaceLearningEngine(context: context)
            await engine.refreshAndDeduplicateAllPlaces(useAI: useAI)
            sampleResultMessage = "✅ 已完成漂移点合并、街道名称反查与「家/公司」角色推断。"
            isRefreshingPlaces = false
            Haptic.success()
        }
    }

    private func sampleCurrentLocation() {
        guard !isSampling else { return }
        isSampling = true
        sampleResultMessage = nil
        Haptic.light()

        Task {
            if let coord = await locationService.requestSingleLocationSample(context: context, requestPermissionIfNeeded: true) {
                let engine = PlaceLearningEngine(context: context)
                await engine.refreshAndDeduplicateAllPlaces(useAI: false)
                if let place = engine.resolveCurrentPlace(wifiSSID: locationService.lastKnownWiFiSSID, coordinate: coord) {
                    let wifiText = locationService.lastKnownWiFiSSID.map { "，已记录 Wi‑Fi「\($0)」" } ?? ""
                    sampleResultMessage = "✅ 已成功采样坐标，当前归属于「\(place.name)」\(wifiText)。"
                } else {
                    let wifiText = locationService.lastKnownWiFiSSID.map { "，已记录 Wi‑Fi「\($0)」" } ?? ""
                    sampleResultMessage = "✅ 采样记录已录入，正在等待进一步聚类分析\(wifiText)。"
                }
                Haptic.success()
            } else {
                sampleResultMessage = "⚠️ 获取定位失败，请确保已在系统「设置」中允许小助访问位置信息。"
                Haptic.error()
            }
            isSampling = false
        }
    }

    private func deletePlaces(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(places[idx])
        }
        try? context.save()
        locationService.syncParcelStationGeofences(context: context)
    }
}

struct PlaceRow: View {
    let place: LearnedPlace

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(categoryColor(for: place.category).opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: place.category.icon)
                    .font(.headline)
                    .foregroundStyle(categoryColor(for: place.category))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.headline)
                        .lineLimit(1)

                    if place.category != .other {
                        Text(L10n.tr(place.category.rawValue))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(categoryColor(for: place.category).opacity(0.15)))
                            .foregroundStyle(categoryColor(for: place.category))
                    }

                    if place.isUserConfirmed {
                        Text("已锁定")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    } else {
                        Text("智能推断")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 6) {
                    Text("累计停留 \(place.visitCount) 次")
                    if place.nightStayProbability >= 0.35 {
                        Text("· 居家特征 \(Int(place.nightStayProbability * 100))%")
                            .foregroundStyle(.blue)
                    } else if place.workdayDayStayProbability >= 0.35 {
                        Text("· 办公特征 \(Int(place.workdayDayStayProbability * 100))%")
                            .foregroundStyle(.indigo)
                    } else if place.latitude != 0 && place.longitude != 0 {
                        Text("· GPS已校准")
                    }
                    if !place.associatedWiFiSSIDs.isEmpty {
                        Text("· Wi-Fi: \(place.associatedWiFiSSIDs.joined(separator: ", "))")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func categoryColor(for cat: PlaceCategory) -> Color {
        switch cat {
        case .home: return .blue
        case .company: return .indigo
        case .parcelStation: return .orange
        case .park: return .green
        case .restaurant: return .pink
        case .other: return .secondary
        }
    }
}

struct LearnedPlaceDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var place: LearnedPlace
    @State private var isUpdatingLocation = false
    @State private var updateLocationFeedback: String?
    @State private var newWiFiSSID = ""

    var body: some View {
        Form {
            Section("地点基本信息") {
                TextField("地点名称", text: $place.name)
                Picker("分类角色", selection: $place.category) {
                    ForEach(PlaceCategory.allCases, id: \.self) { cat in
                        Label(L10n.tr(cat.rawValue), systemImage: cat.icon).tag(cat)
                    }
                }
                Toggle("手动确认并锁定此角色", isOn: $place.isUserConfirmed)
            }

            Section("位置坐标与校准") {
                if place.latitude != 0 && place.longitude != 0 {
                    LabeledContent("经纬度", value: "\(String(format: "%.4f", place.latitude)), \(String(format: "%.4f", place.longitude))")
                    LabeledContent("有效识别半径", value: "\(Int(place.radiusMeters)) 米")
                } else {
                    Text("⚠️ 暂无有效 GPS 坐标，无法触发地理围栏到达与离开提醒。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    updateWithCurrentLocation()
                } label: {
                    HStack {
                        if isUpdatingLocation {
                            ProgressView()
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "location.circle.fill")
                        }
                        Text(isUpdatingLocation ? "正在定位并更新..." : "将当前所在位置覆盖为该地点坐标")
                    }
                }
                .disabled(isUpdatingLocation)

                if let msg = updateLocationFeedback {
                    Text(L10n.tr(msg))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Section("智能学习画像指标") {
                LabeledContent("夜间留宿特征概率") {
                    Text(String(format: "%.0f%%", place.nightStayProbability * 100))
                }
                LabeledContent("工作日白天留宿概率") {
                    Text(String(format: "%.0f%%", place.workdayDayStayProbability * 100))
                }
                LabeledContent("累计驻留记录") {
                    Text("\(place.visitCount) 次")
                }
                LabeledContent("关联 Wi-Fi 数量") {
                    Text("\(place.associatedWiFiSSIDs.count) 个")
                }
            }

            Section("关联 Wi-Fi") {
                if place.associatedWiFiSSIDs.isEmpty {
                    Text("尚未记录 Wi-Fi 名称")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(place.associatedWiFiSSIDs, id: \.self) { ssid in
                        Label(ssid, systemImage: "wifi")
                    }
                    .onDelete { offsets in
                        place.associatedWiFiSSIDs.remove(atOffsets: offsets)
                    }
                }

                HStack {
                    TextField("输入 Wi-Fi 名称", text: $newWiFiSSID)
                    Button("记录") {
                        let ssid = newWiFiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !ssid.isEmpty, !place.associatedWiFiSSIDs.contains(ssid) else { return }
                        place.associatedWiFiSSIDs.append(ssid)
                        newWiFiSSID = ""
                        try? context.save()
                    }
                    .disabled(newWiFiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    captureCurrentWiFi()
                } label: {
                    Label("读取当前 Wi-Fi 并关联", systemImage: "wifi")
                }
                .disabled(isUpdatingLocation)
            }
        }
        .navigationTitle(place.name)
        .onDisappear {
            try? context.save()
            LocationReminderService.shared.syncParcelStationGeofences(context: context)
        }
    }

    private func updateWithCurrentLocation() {
        guard !isUpdatingLocation else { return }
        isUpdatingLocation = true
        updateLocationFeedback = nil
        Task {
            if let coord = await LocationReminderService.shared.requestSingleLocationSample(context: context, requestPermissionIfNeeded: true) {
                place.latitude = coord.latitude
                place.longitude = coord.longitude
                if let ssid = LocationReminderService.shared.lastKnownWiFiSSID,
                   !place.associatedWiFiSSIDs.contains(ssid) {
                    place.associatedWiFiSSIDs.append(ssid)
                }
                try? context.save()
                updateLocationFeedback = LocationReminderService.shared.lastKnownWiFiSSID.map {
                    "已成功校准坐标，并关联 Wi‑Fi「\($0)」！"
                } ?? "已成功校准为当前坐标！"
                Haptic.success()
            }
            isUpdatingLocation = false
        }
    }

    private func captureCurrentWiFi() {
        guard !isUpdatingLocation else { return }
        isUpdatingLocation = true
        updateLocationFeedback = nil
        Task {
            if let ssid = await LocationReminderService.shared.captureCurrentWiFiSSID() {
                if !place.associatedWiFiSSIDs.contains(ssid) {
                    place.associatedWiFiSSIDs.append(ssid)
                }
                try? context.save()
                updateLocationFeedback = "已关联当前 Wi-Fi「\(ssid)」"
                Haptic.success()
            } else {
                updateLocationFeedback = "暂时读取不到 Wi-Fi。当前个人开发团队不支持自动读取 Wi-Fi，请在上方输入框中手动关联网络名称。"
                Haptic.error()
            }
            isUpdatingLocation = false
        }
    }
}

struct AddPlaceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = PlaceCategory.company
    @State private var wifiSSID = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var isLocating: Bool = false
    @State private var locationAcquired: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("地点分类与命名") {
                    Picker("分类角色", selection: $category) {
                        ForEach(PlaceCategory.allCases, id: \.self) { cat in
                            Label(L10n.tr(cat.rawValue), systemImage: cat.icon).tag(cat)
                        }
                    }
                    .onChange(of: category) { _, newCat in
                        if name.isEmpty || name == "公司" || name == "家" || name == "常用驿站" {
                            name = newCat.rawValue
                        }
                    }

                    TextField("名称（如：公司 / 科技园总部）", text: $name)

                    if category == .parcelStation {
                        HStack(spacing: 8) {
                            Text("快捷命名：")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(["菜鸟驿站", "丰巢快递柜", "兔喜生活"], id: \.self) { preset in
                                Button(preset) {
                                    name = preset
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        Text("💡 录入驿站地理坐标后，当你有待取包裹并到达此驿站 120 米地理围栏时，手腕与灵动岛将自动亮起取件码，抬腕轻点「已取件」即可免掏手机销号。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("地理坐标") {
                    Button {
                        fetchCurrentLocation()
                    } label: {
                        HStack {
                            if isLocating {
                                ProgressView()
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "location.fill")
                            }
                            Text(isLocating ? "正在获取当前位置..." : (locationAcquired ? "已获取当前位置 (可点击刷新)" : "📍 一键获取并填入当前 GPS 坐标"))
                        }
                    }
                    .disabled(isLocating)

                    if latitude != 0 && longitude != 0 {
                        HStack {
                            Text("经纬度坐标")
                            Spacer()
                            Text("\(String(format: "%.4f", latitude)), \(String(format: "%.4f", longitude))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("当前连接的 Wi-Fi 名称（可选）", text: $wifiSSID)
                }
            }
            .navigationTitle("添加常用地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? category.rawValue : name
                        let place = LearnedPlace(
                            name: finalName,
                            category: category,
                            latitude: latitude,
                            longitude: longitude,
                            radiusMeters: 200,
                            associatedWiFiSSIDs: wifiSSID.isEmpty ? [] : [wifiSSID],
                            visitCount: 1,
                            isUserConfirmed: true
                        )
                        context.insert(place)
                        try? context.save()
                        LocationReminderService.shared.syncParcelStationGeofences(context: context)
                        Haptic.success()
                        dismiss()
                    }
                }
            }
            .task {
                fetchCurrentLocation()
            }
        }
    }

    private func fetchCurrentLocation() {
        guard !isLocating else { return }
        isLocating = true
        Task {
            if let coord = await LocationReminderService.shared.requestSingleLocationSample(context: context, requestPermissionIfNeeded: true) {
                latitude = coord.latitude
                longitude = coord.longitude
                if wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let ssid = LocationReminderService.shared.lastKnownWiFiSSID {
                    wifiSSID = ssid
                }
                locationAcquired = true

                if name.isEmpty {
                    let hour = Calendar.current.component(.hour, from: .now)
                    let isWeekend = Calendar.current.isDateInWeekend(.now)
                    if !isWeekend && hour >= 9 && hour <= 18 {
                        category = .company
                        name = "公司"
                    } else {
                        category = .home
                        name = "家"
                    }
                }
            }
            isLocating = false
        }
    }
}
