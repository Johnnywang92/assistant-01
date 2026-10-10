import SwiftData
import SwiftUI

/// 常驻地点管理与自学习可视化视图
struct LearnedPlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LearnedPlace.visitCount, order: .reverse) private var places: [LearnedPlace]
    @State private var showingAddPlaceSheet = false

    var body: some View {
        List {
            Section {
                Text("助手会在完全离线状态下，根据你连接的 Wi-Fi、夜间与工作日白天的驻留规律，自主聚类学习推断哪里是「家」、哪里是「公司」。你也可以在此手动校准或添加。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if places.isEmpty {
                ContentUnavailableView(
                    "暂未学习到常驻地点",
                    systemImage: "map",
                    description: Text("随着日常使用与自动化情境触发，助手将自动聚合出常驻生活轨迹。")
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
        .navigationTitle("常用地点与学习")
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
    }

    private func deletePlaces(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(places[idx])
        }
        try? context.save()
    }
}

struct PlaceRow: View {
    let place: LearnedPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.category.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(place.name)
                        .font(.headline)
                    if place.isUserConfirmed {
                        Text("已确认")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    } else {
                        Text("自学习推断")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Text("累计到访 \(place.visitCount) 次")
                    if !place.associatedWiFiSSIDs.isEmpty {
                        Text("· Wi-Fi: \(place.associatedWiFiSSIDs.joined(separator: ", "))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LearnedPlaceDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var place: LearnedPlace

    var body: some View {
        Form {
            Section("地点基本信息") {
                TextField("地点名称", text: $place.name)
                Picker("分类角色", selection: $place.category) {
                    ForEach(PlaceCategory.allCases, id: \.self) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                Toggle("手动确认并锁定此角色", isOn: $place.isUserConfirmed)
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

            if !place.associatedWiFiSSIDs.isEmpty {
                Section("已学习关联的 Wi-Fi") {
                    ForEach(place.associatedWiFiSSIDs, id: \.self) { ssid in
                        HStack {
                            Image(systemName: "wifi")
                            Text(ssid)
                        }
                    }
                }
            }
        }
        .navigationTitle(place.name)
        .onDisappear {
            try? context.save()
        }
    }
}

struct AddPlaceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = PlaceCategory.home
    @State private var wifiSSID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("新增地点") {
                    TextField("名称（如：家 / 科技园公司）", text: $name)
                    Picker("分类角色", selection: $category) {
                        ForEach(PlaceCategory.allCases, id: \.self) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    TextField("当前连接的 Wi-Fi 名称（可选）", text: $wifiSSID)
                }
            }
            .navigationTitle("添加常驻地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let place = LearnedPlace(
                            name: name.isEmpty ? category.rawValue : name,
                            category: category,
                            latitude: 0,
                            longitude: 0,
                            associatedWiFiSSIDs: wifiSSID.isEmpty ? [] : [wifiSSID],
                            isUserConfirmed: true
                        )
                        context.insert(place)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.isEmpty && category == .other)
                }
            }
        }
    }
}
