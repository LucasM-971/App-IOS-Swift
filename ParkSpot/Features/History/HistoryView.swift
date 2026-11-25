// HistoryView.swift
import SwiftUI
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var sessions: [ParkingSession] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasMore = true
    @Published private(set) var isPremiumUser = false
    @Published private(set) var hasLoadedInitialPage = false

    private var currentPage = 0
    private let defaultPageSize = 20
    private let fetchUseCase: FetchHistoryUseCase
    private var userId: UUID?

    private var pageSize: Int {
        defaultPageSize
    }

    init(fetchUseCase: FetchHistoryUseCase) {
        self.fetchUseCase = fetchUseCase
    }

    convenience init() {
        self.init(fetchUseCase: DIContainer.shared.makeFetchHistoryUseCase())
    }

    func updateUser(_ user: User?) async {
        let nextUserId = user?.id
        let nextIsPremium = user.map(HistoryPlanResolver.isPremium) ?? false
        let didUserContextChange = userId != nextUserId || isPremiumUser != nextIsPremium

        if didUserContextChange {
            userId = nextUserId
            isPremiumUser = nextIsPremium
            currentPage = 0
            sessions = []
            hasMore = nextUserId != nil
            error = nil
            hasLoadedInitialPage = false
        }

        guard nextUserId != nil else {
            sessions = []
            hasMore = false
            hasLoadedInitialPage = true
            return
        }

        guard !hasLoadedInitialPage else { return }
        await loadInitial()
    }

    func loadInitial(resetVisibleContent: Bool = true) async {
        guard !isLoading else { return }
        guard let requestedUserId = userId else {
            sessions = []
            hasMore = false
            hasLoadedInitialPage = true
            return
        }

        currentPage = 0
        hasMore = true
        error = nil

        if resetVisibleContent {
            sessions = []
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let firstPage = try await fetchUseCase.execute(
                userId: requestedUserId, page: 0, pageSize: pageSize
            )
            guard !Task.isCancelled, userId == requestedUserId else { return }

            sessions = firstPage
            hasMore = firstPage.count == pageSize
            currentPage = 1
            hasLoadedInitialPage = true
        } catch {
            guard !Task.isCancelled, userId == requestedUserId else { return }
            self.error = error.localizedDescription
            hasLoadedInitialPage = true
        }
    }

    func refresh() async {
        await loadInitial(resetVisibleContent: sessions.isEmpty)
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        guard let requestedUserId = userId else {
            sessions = []
            hasMore = false
            hasLoadedInitialPage = true
            return
        }

        let pageToLoad = currentPage
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            let page = try await fetchUseCase.execute(
                userId: requestedUserId, page: pageToLoad, pageSize: pageSize
            )
            guard !Task.isCancelled, userId == requestedUserId, currentPage == pageToLoad else {
                return
            }

            sessions += page
            hasMore = page.count == pageSize
            currentPage += 1
            hasLoadedInitialPage = true
        } catch {
            guard !Task.isCancelled, userId == requestedUserId else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm: HistoryViewModel
    @State private var searchText = ""

    init() {
        _vm = StateObject(wrappedValue: HistoryViewModel())
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowInitialLoadingState: Bool {
        authSession.isAuthenticated && vm.isLoading && vm.sessions.isEmpty && !vm.hasLoadedInitialPage
    }

    private var filteredSessions: [ParkingSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.sessions }

        return vm.sessions.filter { session in
            let searchableContent = [
                session.address,
                session.note,
                session.parkingLevel
            ]
                .compactMap { $0 }
                .joined(separator: " ")

            return searchableContent.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !authSession.isAuthenticated {
                    signedOutState
                } else if shouldShowInitialLoadingState {
                    initialLoadingState
                } else if vm.sessions.isEmpty && !vm.isLoading {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("tabs.history".psLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.blue)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "history.search_prompt".psLocalized
            )
            .task(id: authSession.currentUser) {
                await vm.updateUser(authSession.currentUser)
            }
            .refreshable {
                guard authSession.isAuthenticated else { return }
                await vm.refresh()
            }
            .onChange(of: vm.error) { _, message in
                guard isHistoryAuthError(message) else { return }
                vm.error = nil
                Task {
                    await authSession.signOut()
                }
            }
            .alert("Erreur".psLocalized, isPresented: .constant(vm.error != nil && !isHistoryAuthError(vm.error))) {
                Button("OK".psLocalized) { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
        }
    }

    private func isHistoryAuthError(_ message: String?) -> Bool {
        let lowered = (message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !lowered.isEmpty else { return false }

        return lowered.contains("unsupported jwt algorithm")
            || lowered.contains("unsupported algorithm es256")
            || lowered.contains("unsupported jwt algirithme es256")
            || (lowered.contains("es256") && lowered.contains("jwt"))
            || (lowered.contains("es256") && lowered.contains("algorithm"))
            || (lowered.contains("es256") && lowered.contains("algorithme"))
            || lowered.contains("unauthorized")
            || lowered.contains("session expired")
            || lowered.contains("request error (401)")
            || lowered.contains("token") && lowered.contains("expired")
    }

    private var signedOutState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.4))

            Text("history.signed_out_title".psLocalized)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                router.navigateToAuthFromSettings()
            } label: {
                Text("Se connecter".psLocalized)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            HStack(spacing: 0) {
                Text("history.no_account".psLocalized)
                    .foregroundColor(.secondary)
                Button {
                    router.navigateToAuthFromSettings(mode: .signUp)
                } label: {
                    Text("history.create_account".psLocalized)
                        .foregroundColor(.blue)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
    }

    private var initialLoadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("history.loading_title".psLocalized)
                .font(.headline)

            Text("history.loading_subtitle".psLocalized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        List {
            if filteredSessions.isEmpty {
                noSearchResultState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredSessions) { session in
                    NavigationLink(destination: ParkingDetailView(session: session)) {
                        HistoryRow(session: session)
                    }
                    .listRowBackground(Color(.secondarySystemBackground))
                }
            }

            if vm.hasMore && !isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .onAppear { Task { await vm.loadNextPage() } }
            }

            if shouldShowPremiumHistoryUpsell {
                premiumHistoryUpsellRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
    }

    private var shouldShowPremiumHistoryUpsell: Bool {
        authSession.isAuthenticated
            && !vm.isPremiumUser
            && !vm.hasMore
            && !vm.sessions.isEmpty
            && !isSearching
    }

    private var premiumHistoryUpsellRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)

            Text("To see more history, upgrade to Premium.".psLocalized)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var noSearchResultState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("history.no_results_title".psLocalized)
                .font(.headline)

            Text("history.no_results_subtitle".psLocalized)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.4))
            Text("history.empty_title".psLocalized)
                .font(.title3.bold())
            Text("history.empty_subtitle".psLocalized)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

struct HistoryRow: View {
    let session: ParkingSession

    var duration: String {
        guard let end = session.endTime else { return "history.ongoing".psLocalized }
        let secs = end.timeIntervalSince(session.startTime)
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h > 0 {
            return String(format: "common.duration_h_m_format".psLocalized, h, m)
        }
        return String(format: "common.duration_m_format".psLocalized, m)
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "car.fill")
                        .foregroundColor(.blue)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.address ?? "Position enregistrée".psLocalized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(duration)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.1), in: Capsule())
        }
        .padding(.vertical, 4)
    }
}
