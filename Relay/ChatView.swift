import SwiftUI

// MARK: - Design Theme Constants

private enum ChatTheme {
    static let background = Color(red: 0.039, green: 0.039, blue: 0.039)        // #0a0a0a
    static let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)   // #1a1a1a
    static let border = Color(red: 0.165, green: 0.165, blue: 0.165)           // #2a2a2a
    static let userBubble = Color(red: 0.165, green: 0.165, blue: 0.165)       // #2a2a2a
    static let assistantBubble = Color(red: 0.078, green: 0.09, blue: 0.102)   // #14171a
    static let rawBubble = Color(red: 0.055, green: 0.055, blue: 0.055)         // #0e0e0e

    static let claude = Color(red: 215 / 255, green: 117 / 255, blue: 87 / 255) // #d77557
    static let codex = Color(red: 116 / 255, green: 185 / 255, blue: 255 / 255) // #74b9ff
    static let gemini = Color(red: 142 / 255, green: 108 / 255, blue: 239 / 255) // #8e6cef
    static let openrouter = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255) // #4ade80

    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)               // #ff6b6b
    static let dangerBg = Color(red: 0.165, green: 0.08, blue: 0.08)            // #2a1414
    static let dangerBorder = Color(red: 0.29, green: 0.12, blue: 0.12)         // #4a1f1f

    static let busy = Color(red: 1.0, green: 0.69, blue: 0.125)                // #ffb020
    static let success = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255) // #4ade80
    static let textDim = Color(red: 0.54, green: 0.54, blue: 0.54)             // #8a8a8a
    static let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)         // #f2f2f2

    static func backendAccent(_ backend: BackendId) -> Color {
        switch backend {
        case .claude: return claude
        case .codex: return codex
        case .gemini: return gemini
        case .openrouter: return openrouter
        }
    }
}

// MARK: - ChatView

/// Main chat screen for an active Relay session.
/// Polls `GET /api/sessions/{name}?lines=500` every 3s while visible with cancellation on disappear.
struct ChatView: View {
    let sessionName: String
    private let apiClient: RelayAPIClient

    @State private var sessionDetail: SessionDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var inputMessage = ""
    @State private var isSending = false
    @State private var isStopping = false
    @State private var isShowingModelSwitchSheet = false
    @State private var isShowingDowngradeSheet = false
    @State private var pollTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    init(sessionName: String, apiClient: RelayAPIClient = .shared) {
        self.sessionName = sessionName
        self.apiClient = apiClient
    }

    private var isBusy: Bool {
        sessionDetail?.status == "busy"
    }

    var body: some View {
        ZStack {
            ChatTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                subbarView
                contentView
                bottomInputBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ChatTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationHeader
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                trailingToolbarItems
            }
        }
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
        .sheet(isPresented: $isShowingModelSwitchSheet) {
            ModelSwitchSheet(sessionName: sessionName, onSaved: {
                Task {
                    await loadDetail()
                }
            }, apiClient: apiClient)
        }
        .sheet(isPresented: $isShowingDowngradeSheet) {
            DowngradeSheet(sessionName: sessionName, onDowngraded: {
                Task {
                    await loadDetail()
                }
            }, apiClient: apiClient)
        }
    }

    // MARK: - Navigation Header & Toolbar

    private var navigationHeader: some View {
        VStack(spacing: 2) {
            Text(sessionName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ChatTheme.textPrimary)
                .lineLimit(1)

            if let status = sessionDetail?.status {
                StatusBadge(status: status)
            }
        }
    }

    @ViewBuilder
    private var trailingToolbarItems: some View {
        if isBusy {
            Button(action: stopSession) {
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ChatTheme.danger)
            }
            .disabled(isStopping)
        }

        Button {
            isShowingModelSwitchSheet = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundColor(ChatTheme.claude)
                .accessibilityLabel("Change Model")
        }

        if !(sessionDetail?.lockedToFree ?? false) && sessionDetail?.backend != .openrouter {
            Button {
                isShowingDowngradeSheet = true
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(ChatTheme.openrouter)
                    .accessibilityLabel("Downgrade to Free")
            }
        }
    }

    // MARK: - Subbar (Model & Downgrade Chips)

    private var subbarView: some View {
        HStack(spacing: 8) {
            Button {
                isShowingModelSwitchSheet = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(sessionDetail.map { ChatTheme.backendAccent($0.backend) } ?? ChatTheme.claude)
                        .frame(width: 7, height: 7)

                    Text(modelChipText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ChatTheme.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ChatTheme.cardBackground)
                .cornerRadius(999)
                .overlay(
                    Capsule()
                        .stroke(ChatTheme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if !(sessionDetail?.lockedToFree ?? false) && sessionDetail?.backend != .openrouter {
                Button {
                    isShowingDowngradeSheet = true
                } label: {
                    Text("Switch to free")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ChatTheme.openrouter)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ChatTheme.cardBackground)
                        .cornerRadius(999)
                        .overlay(
                            Capsule()
                                .stroke(ChatTheme.openrouter, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ChatTheme.background)
        .overlay(
            Divider().background(ChatTheme.border),
            alignment: .bottom
        )
    }

    private var modelChipText: String {
        guard let detail = sessionDetail else {
            return "Loading…"
        }
        var text = detail.backend.displayName
        if let model = detail.model, !model.isEmpty {
            text += " · \(model)"
        }
        if let effort = detail.effort, !effort.isEmpty {
            text += " (\(effort))"
        }
        return text
    }

    // MARK: - Main Content

    @ViewBuilder
    private var contentView: some View {
        if isLoading && sessionDetail == nil {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .tint(.white)
                Text("Loading chat…")
                    .font(.subheadline)
                    .foregroundColor(ChatTheme.textDim)
                Spacer()
            }
        } else if let errorMessage, sessionDetail == nil {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(ChatTheme.danger)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(ChatTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry") {
                    Task {
                        await loadDetail()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(ChatTheme.cardBackground)
                .foregroundColor(.white)
                .cornerRadius(8)
                Spacer()
            }
        } else if let detail = sessionDetail {
            turnsScrollView(detail: detail)
        }
    }

    private func turnsScrollView(detail: SessionDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if detail.turns.isEmpty {
                        VStack(spacing: 8) {
                            Text("No messages in this session yet.")
                                .font(.subheadline)
                                .foregroundColor(ChatTheme.textDim)
                            Text("Send a message below to begin.")
                                .font(.caption)
                                .foregroundColor(ChatTheme.textDim.opacity(0.8))
                        }
                        .padding(.top, 48)
                    } else {
                        ForEach(Array(detail.turns.enumerated()), id: \.offset) { index, turn in
                            ChatTurnRow(
                                turn: turn,
                                isRawSnapshot: detail.transcriptMode == "raw_snapshot",
                                backendName: detail.backend.displayName
                            )
                            .id(index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: detail.turns.count) { newCount in
                if newCount > 0 {
                    withAnimation {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if !detail.turns.isEmpty {
                    proxy.scrollTo(detail.turns.count - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Bottom Input Bar

    private var bottomInputBar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(ChatTheme.border)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message...", text: $inputMessage, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ChatTheme.cardBackground)
                    .foregroundColor(ChatTheme.textPrimary)
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(ChatTheme.border, lineWidth: 1)
                    )

                if isBusy {
                    Button(action: stopSession) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Stop")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(ChatTheme.danger)
                        .cornerRadius(18)
                    }
                    .disabled(isStopping)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 36, height: 36)
                            .background(canSend ? ChatTheme.claude : ChatTheme.claude.opacity(0.35))
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(ChatTheme.background)
        }
    }

    private var canSend: Bool {
        !isBusy && !isSending && !inputMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Polling & Actions

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await loadDetail()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadDetail() async {
        do {
            let detail = try await apiClient.getSessionDetail(sessionName: sessionName)
            if !Task.isCancelled {
                self.sessionDetail = detail
                self.errorMessage = nil
            }
        } catch {
            if !Task.isCancelled {
                self.errorMessage = error.localizedDescription
            }
        }
        if isLoading {
            isLoading = false
        }
    }

    private func sendMessage() {
        let textToSend = inputMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSend.isEmpty, !isBusy, !isSending else { return }

        inputMessage = ""
        isSending = true

        Task {
            do {
                try await apiClient.sendMessage(sessionName: sessionName, text: textToSend)
                await loadDetail()
            } catch {
                errorMessage = "Failed to send: \(error.localizedDescription)"
            }
            isSending = false
        }
    }

    private func stopSession() {
        guard !isStopping else { return }
        isStopping = true

        Task {
            do {
                try await apiClient.stopSession(sessionName: sessionName)
                await loadDetail()
            } catch {
                errorMessage = "Failed to stop: \(error.localizedDescription)"
            }
            isStopping = false
        }
    }
}

// MARK: - Turn Row & Bubble Views

private struct ChatTurnRow: View {
    let turn: Turn
    let isRawSnapshot: Bool
    let backendName: String

    var body: some View {
        if isRawSnapshot && turn.role != "user" {
            rawTerminalBlock
        } else if turn.role == "user" {
            userBubble
        } else if turn.role == "error" || turn.isError {
            errorBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 44)

            Text(turn.text)
                .font(.system(size: 15))
                .foregroundColor(ChatTheme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ChatTheme.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(turn.text)
                    .font(.system(size: 15))
                    .foregroundColor(ChatTheme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)

                if let cost = turn.costUsd {
                    Text(String(format: "$%.4f", cost))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ChatTheme.textDim)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatTheme.assistantBubble)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ChatTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 44)
        }
    }

    private var errorBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Error")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(ChatTheme.danger)

                Text(turn.text)
                    .font(.system(size: 15))
                    .foregroundColor(ChatTheme.danger)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatTheme.dangerBg)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ChatTheme.dangerBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 44)
        }
    }

    private var rawTerminalBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 0.3, green: 0.8, blue: 0.3))
                    .frame(width: 6, height: 6)

                Text("\(backendName.uppercased()) (LIVE VIEW)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(ChatTheme.textDim)
            }

            Text(turn.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.92))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.rawBubble)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChatTheme.border, lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: String
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(status == "busy" && isPulsing ? 0.3 : 1.0)

            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background)
        .foregroundColor(color)
        .clipShape(Capsule())
        .onAppear {
            if status == "busy" {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    private var text: String {
        switch status {
        case "busy": return "thinking…"
        case "idle": return "idle"
        case "error": return "error"
        default: return "stopped"
        }
    }

    private var color: Color {
        switch status {
        case "busy": return ChatTheme.busy
        case "idle": return ChatTheme.success
        case "error": return ChatTheme.danger
        default: return ChatTheme.textDim
        }
    }

    private var background: Color {
        switch status {
        case "busy": return Color(red: 0.165, green: 0.14, blue: 0.06)
        case "idle": return Color(red: 0.12, green: 0.165, blue: 0.12)
        case "error": return ChatTheme.dangerBg
        default: return Color(white: 0.13)
        }
    }
}

// MARK: - ModelSwitchSheet

/// Sheet allowing the user to switch the model or reasoning effort for a session.
/// Calls `POST /api/sessions/{name}/model`.
struct ModelSwitchSheet: View {
    let sessionName: String
    var onSaved: (() -> Void)?
    private let apiClient: RelayAPIClient

    @State private var availableModels: [ModelOption] = []
    @State private var selectedModel: String = ""
    @State private var selectedEffort: String = ""
    @State private var currentBackend: BackendId = .claude
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    private let effortOptions = ["", "low", "medium", "high", "xhigh", "max"]

    init(
        sessionName: String,
        onSaved: (() -> Void)? = nil,
        apiClient: RelayAPIClient = .shared
    ) {
        self.sessionName = sessionName
        self.onSaved = onSaved
        self.apiClient = apiClient
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChatTheme.background
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading models…")
                        .tint(.white)
                        .foregroundColor(.white)
                } else {
                    Form {
                        Section(header: Text("Model").foregroundColor(ChatTheme.textDim)) {
                            Picker("Model", selection: $selectedModel) {
                                Text("(default)").tag("")
                                ForEach(availableModels) { option in
                                    Text(option.label).tag(option.idValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(ChatTheme.cardBackground)
                        }

                        Section(header: Text("Effort (optional)").foregroundColor(ChatTheme.textDim)) {
                            Picker("Effort", selection: $selectedEffort) {
                                Text("default").tag("")
                                Text("low").tag("low")
                                Text("medium").tag("medium")
                                Text("high").tag("high")
                                Text("xhigh").tag("xhigh")
                                Text("max").tag("max")
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(ChatTheme.cardBackground)
                        }

                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundColor(ChatTheme.danger)
                            }
                            .listRowBackground(ChatTheme.dangerBg)
                        }

                        Section {
                            Button(action: saveChanges) {
                                HStack {
                                    Spacer()
                                    if isSaving {
                                        ProgressView()
                                            .tint(.black)
                                    } else {
                                        Text("Apply")
                                            .font(.headline)
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isSaving)
                            .padding(.vertical, 4)
                            .listRowBackground(ChatTheme.claude)
                            .foregroundColor(.black)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Change Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ChatTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(ChatTheme.claude)
                }
            }
            .task {
                await loadCurrentStateAndModels()
            }
        }
    }

    private func loadCurrentStateAndModels() async {
        isLoading = true
        errorMessage = nil
        do {
            let detail = try await apiClient.getSessionDetail(sessionName: sessionName)
            currentBackend = detail.backend
            selectedModel = detail.model ?? ""
            selectedEffort = detail.effort ?? ""

            let models = try await apiClient.getModels(backend: detail.backend)
            availableModels = models
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func saveChanges() {
        guard !isSaving else { return }
        errorMessage = nil
        isSaving = true

        Task {
            do {
                let modelVal = selectedModel.isEmpty ? nil : selectedModel
                let effortVal = selectedEffort.isEmpty ? nil : selectedEffort

                if modelVal == nil && effortVal == nil {
                    errorMessage = "Pick a model and/or effort to change."
                    isSaving = false
                    return
                }

                let modelSwitch = ModelSwitch(model: modelVal, effort: effortVal)
                _ = try await apiClient.switchModel(sessionName: sessionName, modelSwitch: modelSwitch)
                onSaved?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - DowngradeSheet

/// Confirmation sheet with a native confirm-style alert warning the user that
/// downgrading to the OpenRouter free tier is ONE-WAY and cannot be undone.
/// Calls `POST /api/sessions/{name}/downgrade`.
struct DowngradeSheet: View {
    let sessionName: String
    var onDowngraded: (() -> Void)?
    private let apiClient: RelayAPIClient

    @State private var freeModels: [ModelOption] = []
    @State private var selectedModel: String = ""
    @State private var isLoading = true
    @State private var isDowngrading = false
    @State private var errorMessage: String?
    @State private var showConfirmAlert = false

    @Environment(\.dismiss) private var dismiss

    init(
        sessionName: String,
        onDowngraded: (() -> Void)? = nil,
        apiClient: RelayAPIClient = .shared
    ) {
        self.sessionName = sessionName
        self.onDowngraded = onDowngraded
        self.apiClient = apiClient
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChatTheme.background
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading free models…")
                        .tint(.white)
                        .foregroundColor(.white)
                } else {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(ChatTheme.busy)
                                        .font(.title3)

                                    Text("Permanent One-Way Downgrade")
                                        .font(.headline)
                                        .foregroundColor(ChatTheme.textPrimary)
                                }

                                Text("Switching this session to the OpenRouter free tier carries your prior conversation forward as seed context. However, you can NEVER switch back to Claude, Codex, Gemini, or any paid backend for this session again.")
                                    .font(.subheadline)
                                    .foregroundColor(ChatTheme.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color(red: 0.165, green: 0.14, blue: 0.06))

                        Section(header: Text("Free Model (optional)").foregroundColor(ChatTheme.textDim)) {
                            Picker("Model", selection: $selectedModel) {
                                Text("(auto-cascade default)").tag("")
                                ForEach(freeModels) { option in
                                    Text(option.label).tag(option.idValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(ChatTheme.cardBackground)
                        }

                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundColor(ChatTheme.danger)
                            }
                            .listRowBackground(ChatTheme.dangerBg)
                        }

                        Section {
                            Button(role: .destructive) {
                                showConfirmAlert = true
                            } label: {
                                HStack {
                                    Spacer()
                                    if isDowngrading {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Text("Downgrade to Free Tier")
                                            .font(.headline)
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isDowngrading)
                            .padding(.vertical, 4)
                            .listRowBackground(ChatTheme.danger)
                            .foregroundColor(.white)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Switch to Free Tier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ChatTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(ChatTheme.claude)
                }
            }
            .alert("Confirm Downgrade", isPresented: $showConfirmAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Downgrade to Free", role: .destructive) {
                    performDowngrade()
                }
            } message: {
                Text("This downgrade to OpenRouter free tier is ONE-WAY and cannot be undone. You will never be able to return to a paid backend for this session.")
            }
            .task {
                await loadFreeModels()
            }
        }
    }

    private func loadFreeModels() async {
        isLoading = true
        errorMessage = nil
        do {
            freeModels = try await apiClient.getModels(backend: .openrouter)
        } catch {
            errorMessage = "Failed to load free models: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func performDowngrade() {
        guard !isDowngrading else { return }
        isDowngrading = true
        errorMessage = nil

        Task {
            do {
                let modelVal = selectedModel.isEmpty ? nil : selectedModel
                let req = DowngradeRequest(model: modelVal)
                _ = try await apiClient.downgradeSession(sessionName: sessionName, request: req)
                onDowngraded?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDowngrading = false
            }
        }
    }
}
