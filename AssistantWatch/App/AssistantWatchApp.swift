import AssistantCore
import SwiftUI

@main
struct AssistantWatchApp: App {
    @StateObject private var store = WatchStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.requestRefresh()
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        let path = url.host ?? url.path
        if path.contains("parcel") || path.contains("pickup") {
            store.selectedTab = .parcels
        } else if path.contains("checklist") || path.contains("departure") || path.contains("travel") {
            store.selectedTab = .departure
        } else if path.contains("todos") && store.displaySnapshot.travelSnapshot != nil {
            store.selectedTab = .departure
        } else if path.contains("expense") || path.contains("capture") {
            store.selectedTab = .quickCapture
        } else if path.contains("health") || path.contains("vitality") || path.contains("pleasure") {
            store.selectedTab = .health
        } else if path.contains("mood") {
            store.selectedTab = .mood
        } else if path.contains("water") {
            store.selectedTab = .water
        } else {
            store.selectedTab = .today
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        // 按日常腕上高频使用频次从高到低排序：
        // 1. 今天（总览/待办/吃药习惯） → 2. 快速记（日均多次记账/记事） → 3. 喝水（日均 5~8 次）
        // → 4. 取件码 → 5. 出行清点 → 6. 心情打卡 → 7. 身心状态
        TabView(selection: $store.selectedTab) {
            WatchTodayView()
                .tag(WatchTab.today)

            WatchQuickCaptureView()
                .tag(WatchTab.quickCapture)

            WatchWaterView()
                .tag(WatchTab.water)

            WatchParcelsView()
                .tag(WatchTab.parcels)

            WatchDepartureView()
                .tag(WatchTab.departure)

            WatchMoodCheckInView()
                .tag(WatchTab.mood)

            WatchHealthView()
                .tag(WatchTab.health)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            if let banner = store.lastReplyBanner {
                Text(banner)
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.92)))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
