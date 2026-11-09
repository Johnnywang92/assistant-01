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
        } else if path.contains("expense") || path.contains("capture") {
            store.selectedTab = .quickCapture
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
        TabView(selection: $store.selectedTab) {
            WatchTodayView()
                .tag(WatchTab.today)

            WatchParcelsView()
                .tag(WatchTab.parcels)

            WatchQuickCaptureView()
                .tag(WatchTab.quickCapture)

            WatchMoodCheckInView()
                .tag(WatchTab.mood)

            WatchWaterView()
                .tag(WatchTab.water)
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
