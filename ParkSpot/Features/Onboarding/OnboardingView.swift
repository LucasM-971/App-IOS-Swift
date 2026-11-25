import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app.hasCompletedWelcome") private var hasCompletedWelcome = false
    @AppStorage("debug.onboarding.forceVisible") private var debugOnboardingForceVisible = false
    @AppStorage("debug.onboarding.startStage") private var debugOnboardingStartStage = ""
    @AppStorage("debug.onboarding.startPage") private var debugOnboardingStartPage = 0
    @State private var currentPage = 0

    private let pages: [OnboardingSlide] = [
        .init(
            icon: "location.north.circle.fill",
            title: "Find your car instantly",
            subtitle: "No stress. No guess."
        ),
        .init(
            icon: "location.north.line.fill",
            title: "Instant directions",
            subtitle: "Back to your car in seconds"
        ),
        .init(
            icon: "car.fill",
            title: "Smart guidance",
            subtitle: "Clear, simple navigation"
        ),
        .init(
            icon: "bell.fill",
            title: "Never forget",
            subtitle: "Parking reminders included"
        ),
        .init(
            icon: "person.fill",
            title: "Create your account",
            subtitle: "Sync your parking across devices"
        ),
    ]

    private var isLastPage: Bool {
        currentPage == pages.count - 1
    }

    private let primaryBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var surfaceBackground: Color {
        isDarkMode
            ? Color(red: 10 / 255, green: 14 / 255, blue: 20 / 255)
            : Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
    }

    var body: some View {
        ZStack {
            surfaceBackground
                .ignoresSafeArea()

            backgroundLighting

            VStack(spacing: 0) {
                topBar

                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, slide in
                        OnboardingSlideCard(
                            slide: slide,
                            primaryBlue: primaryBlue,
                            isDarkMode: isDarkMode
                        )
                            .tag(index)
                            .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                controls
            }
            .frame(maxWidth: 430)
        }
        .onAppear {
            applyDebugOnboardingStartIfNeeded()
            redirectIfLogged()
        }
        .onChange(of: authSession.currentUser?.id) { _, _ in
            redirectIfLogged()
        }
    }

    private func completeAsGuest() {
        hasCompletedWelcome = true
        router.navigateTo(.main)
    }

    private func goToAuth(mode: AuthEntryMode = .signIn) {
        hasCompletedWelcome = true
        router.authEntryMode = mode
        router.navigateTo(.auth)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if !isLastPage {
                Button("Skip".psLocalized) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentPage = pages.count - 1
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDarkMode ? .white.opacity(0.82) : .secondary)
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? primaryBlue : (isDarkMode ? Color.white.opacity(0.22) : Color.black.opacity(0.14)))
                        .frame(
                            width: index == currentPage ? 8 : 6,
                            height: index == currentPage ? 8 : 6
                        )
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }

            VStack(spacing: 10) {
                Button {
                    if isLastPage {
                        goToAuth(mode: .signUp)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentPage += 1
                        }
                    }
                } label: {
                    Text(isLastPage ? "Sign up".psLocalized : "Continue".psLocalized)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(primaryBlue)
                        )
                        .shadow(color: primaryBlue.opacity(0.24), radius: 12, y: 6)
                }
                .buttonStyle(.plain)

                if isLastPage {
                    Button {
                        completeAsGuest()
                    } label: {
                        Text("Continue without account".psLocalized)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(primaryBlue)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private var backgroundLighting: some View {
        ZStack {
            RadialGradient(
                colors: [primaryBlue.opacity(isDarkMode ? 0.18 : 0.10), .clear],
                center: .topLeading,
                startRadius: 12,
                endRadius: 360
            )

            LinearGradient(
                colors: [isDarkMode ? Color.white.opacity(0.04) : .white.opacity(0.72), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func redirectIfLogged() {
        #if DEBUG
            if debugOnboardingForceVisible {
                return
            }
        #endif
        guard authSession.isLogged else { return }
        if router.currentRoute != .main {
            router.navigateTo(.main)
        }
    }

    private func applyDebugOnboardingStartIfNeeded() {
        #if DEBUG
            guard debugOnboardingForceVisible else { return }

            switch debugOnboardingStartStage {
            case "postIntroChoice":
                currentPage = pages.count - 1
            case "intro":
                currentPage = min(max(debugOnboardingStartPage, 0), pages.count - 1)
            default:
                currentPage = 0
            }
        #endif
    }
}

struct OnboardingSlide {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
}
