import SwiftUI

/// Main screen displaying the list of active/existing Relay sessions.
/// Polls `GET /api/sessions` every 5 seconds while visible.
struct SessionListView: View {
    let apiClient: RelayAPIClient

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingNewSessionSheet = false
    @State private var isShowingUsage = false
    @State private var pollTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    init(apiClient: RelayAPIClient = RelayAPIClient()) {
        self.apiClient = apiClient
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(red: 0.039, green: 0.039, blue: 0.039)
                    .ignoresSafeArea()

                contentView

                floatingActionButton
            }
            .navigationTitle("Relay")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.039, green: 0.039, blue: 0.039), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingUsage = true
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                    }
                }
            }
            .sheet(isPresented: $isShowingUsage) {
                UsageView(apiClient: apiClient)
            }
            .preferredColorScheme(.dark)
            .onAppear {
                startPolling()
            }
            .onDisappear {
                stopPolling()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    startPolling()
                } else {
                    stopPolling()
                }
            }
            .sheet(isPresented: $isShowingNewSessionSheet, onDismiss: {
                Task {
                    await loadSessions()
                }
            }) {
                NewSessionSheet()
                    .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contentView: some View {
        if isLoading && sessions.isEmpty {
            loadingView
        } else if let errorMessage, sessions.isEmpty {
            errorView(message: errorMessage)
        } else if sessions.isEmpty {
            emptyStateView
        } else {
            sessionListView
        }
    }

    private var sessionListView: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(destination: ChatView(sessionName: session.name)) {
                    SessionRowView(session: session)
                }
                .listRowBackground(Color(red: 0.102, green: 0.102, blue: 0.102))
                .listRowSeparatorTint(Color(red: 0.165, green: 0.165, blue: 0.165))
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.039, green: 0.039, blue: 0.039))
        .refreshable {
            await loadSessions()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 72)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Loading sessions…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("Couldn't load sessions")
                .font(.headline)
                .foregroundColor(.white)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Retry") {
                Task {
                    await loadSessions()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.843, green: 0.459, blue: 0.341))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Text("No sessions yet.")
                .font(.headline)
                .foregroundColor(.white)

            Text("Tap + to start one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var floatingActionButton: some View {
        Button {
            isShowingNewSessionSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.black)
                .frame(width: 56, height: 56)
                .background(Color(red: 0.843, green: 0.459, blue: 0.341)) // Claude orange accent
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel("New session")
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Polling & Networking

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            await loadSessions()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await loadSessions()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    private func loadSessions() async {
        if sessions.isEmpty && errorMessage == nil {
            isLoading = true
        }

        do {
            let fetched = try await apiClient.fetchSessions()
            self.sessions = fetched
            self.errorMessage = nil
            self.isLoading = false
        } catch {
            // If we already have sessions, don't clear them on periodic polling failure
            if sessions.isEmpty {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                BackendBadge(backend: session.backend)

                Text(session.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                StatusPill(status: session.status)
            }

            HStack(spacing: 6) {
                if let model = session.model, !model.isEmpty {
                    Text(model)
                        .font(.caption)
                        .foregroundColor(Color(red: 0.541, green: 0.541, blue: 0.541))
                        .lineLimit(1)

                    Text("·")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.541, green: 0.541, blue: 0.541))
                }

                if session.lockedToFree {
                    Text("free")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.18))
                        .foregroundColor(Color(red: 0.290, green: 0.871, blue: 0.502))
                        .clipShape(Capsule())

                    Text("·")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.541, green: 0.541, blue: 0.541))
                }

                if let timeText = formatRelativeTime(from: session.lastActivityAt ?? session.createdAt) {
                    Text(timeText)
                        .font(.caption)
                        .foregroundColor(Color(red: 0.541, green: 0.541, blue: 0.541))
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func formatRelativeTime(from isoString: String?) -> String? {
        guard let isoString, !isoString.isEmpty else { return nil }

        let date: Date?
        let formatter = ISO8601DateFormatter()
        if let parsed = formatter.date(from: isoString) {
            date = parsed
        } else {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: isoString)
        }

        guard let date else { return nil }

        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            let minutes = max(1, Int(seconds / 60))
            return "\(minutes)m ago"
        } else if seconds < 86400 {
            let hours = max(1, Int(seconds / 3600))
            return "\(hours)h ago"
        } else {
            let days = max(1, Int(seconds / 86400))
            return "\(days)d ago"
        }
    }
}

// MARK: - Backend Badge

private struct BackendBadge: View {
    let backend: BackendId

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)

            Text(displayName)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(accentColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(accentColor.opacity(0.14))
        .clipShape(Capsule())
    }

    private var displayName: String {
        switch backend {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    private var accentColor: Color {
        switch backend {
        case .claude:
            // Claude terracotta orange (#d77557)
            return Color(red: 0.843, green: 0.459, blue: 0.341)
        case .codex:
            // Codex blue (#74b9ff)
            return Color(red: 0.455, green: 0.725, blue: 1.0)
        case .gemini:
            // Gemini purple (#8e6cef)
            return Color(red: 0.557, green: 0.424, blue: 0.937)
        case .openrouter:
            // OpenRouter green (#4ade80)
            return Color(red: 0.290, green: 0.871, blue: 0.502)
        }
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: String

    @State private var isPulsing = false

    private var isBusy: Bool {
        status.lowercased() == "busy"
    }

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                Circle()
                    .fill(foregroundColor)
                    .frame(width: 6, height: 6)
                    .opacity(isPulsing ? 0.3 : 1.0)
            }

            Text(displayText)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(backgroundColor)
        .foregroundColor(foregroundColor)
        .clipShape(Capsule())
        .onAppear {
            updatePulsing(for: status)
        }
        .onChange(of: status) { newStatus in
            updatePulsing(for: newStatus)
        }
    }

    private func updatePulsing(for currentStatus: String) {
        if currentStatus.lowercased() == "busy" {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        } else {
            withAnimation(.default) {
                isPulsing = false
            }
        }
    }

    private var displayText: String {
        switch status.lowercased() {
        case "busy": return "thinking…"
        case "idle": return "idle"
        case "error": return "error"
        case "not_running": return "stopped"
        default: return status
        }
    }

    private var foregroundColor: Color {
        switch status.lowercased() {
        case "busy":
            // Warm amber (#ffb020)
            return Color(red: 1.0, green: 0.690, blue: 0.125)
        case "idle":
            // Success green (#4ade80)
            return Color(red: 0.290, green: 0.871, blue: 0.502)
        case "error":
            // Danger red (#ff6b6b)
            return Color(red: 1.0, green: 0.420, blue: 0.420)
        case "not_running":
            // Dim text (#8a8a8a)
            return Color(red: 0.541, green: 0.541, blue: 0.541)
        default:
            return Color(red: 0.541, green: 0.541, blue: 0.541)
        }
    }

    private var backgroundColor: Color {
        switch status.lowercased() {
        case "busy":
            return Color(red: 0.165, green: 0.141, blue: 0.063) // #2a2410
        case "idle":
            return Color(red: 0.122, green: 0.165, blue: 0.122) // #1f2a1f
        case "error":
            return Color(red: 0.165, green: 0.078, blue: 0.078) // #2a1414
        case "not_running":
            return Color(red: 0.133, green: 0.133, blue: 0.133) // #222222
        default:
            return Color(red: 0.133, green: 0.133, blue: 0.133)
        }
    }
}
