// MainTabView.swift

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var authSession: AuthSession
    @State private var selectedTab: Tab = .home

    enum Tab: Int {
        case home, parking, history, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("tabs.home".psLocalized, systemImage: "car.fill") }
                .tag(Tab.home)

            LazyTabContent {
                MapView()
            }
                .tabItem {
                    Label("tabs.parking".psLocalized, systemImage: "parkingsign.circle.fill")
                }
                .tag(Tab.parking)

            LazyTabContent {
                HistoryView()
            }
                .tabItem { Label("tabs.history".psLocalized, systemImage: "clock.fill") }
                .tag(Tab.history)

            LazyTabContent {
                SettingsView()
            }
                .tabItem { Label("tabs.settings".psLocalized, systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Color("BrandBlue"))
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color(.systemBackground), for: .tabBar)
    }
}

private struct LazyTabContent<Content: View>: View {
    @State private var hasAppeared = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if hasAppeared {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear {
            hasAppeared = true
        }
    }
}
