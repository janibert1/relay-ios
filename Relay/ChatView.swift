import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A file/photo already uploaded via POST /api/sessions/{name}/files,
/// waiting to be attached to the NEXT message sent. Upload happens
/// immediately on picking (not deferred to send-time) since the backend
/// already needs the file to exist on disk before a message referencing
/// it makes sense.
private struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let relayPath: String
    let displayName: String
    let warning: String?
}

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

    // File/photo attach — built 2026-09-22, Jan: "im missing the file and
    // photo upload." The API client (uploadFile/sendMessage filePaths:)
    // already existed from the original build; there was just never any
    // UI to actually pick something and call it.
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var isUploadingAttachment = false
    @State private var attachError: String?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isShowingFileImporter = false

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
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await uploadPickedFile(url: url) }
                }
            case .failure(let error):
                attachError = error.localizedDescription
            }
        }
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                await uploadPickedPhoto(item: newItem)
                photoPickerItem = nil
            }
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
                            .equatable()
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

            if !pendingAttachments.isEmpty || isUploadingAttachment {
                attachmentChipRow
            }

            if let attachError {
                HStack {
                    Text(attachError)
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.danger)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Choose File", systemImage: "doc")
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(ChatTheme.textDim)
                }
                .disabled(isUploadingAttachment)

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
        let hasContent = !inputMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
        return !isBusy && !isSending && !isUploadingAttachment && hasContent
    }

    private var attachmentChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isUploadingAttachment {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Uploading…")
                            .font(.system(size: 12))
                            .foregroundColor(ChatTheme.textDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ChatTheme.cardBackground)
                    .cornerRadius(14)
                }
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11))
                        Text(attachment.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Button {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                        }
                    }
                    .foregroundColor(ChatTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ChatTheme.cardBackground)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(ChatTheme.border, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    @MainActor
    private func uploadPickedFile(url: URL) async {
        isUploadingAttachment = true
        attachError = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let response = try await apiClient.uploadFile(sessionName: sessionName, fileURL: url)
            pendingAttachments.append(
                PendingAttachment(relayPath: response.path, displayName: url.lastPathComponent, warning: response.warning)
            )
            attachError = response.warning
        } catch {
            attachError = error.localizedDescription
        }
        isUploadingAttachment = false
    }

    @MainActor
    private func uploadPickedPhoto(item: PhotosPickerItem) async {
        isUploadingAttachment = true
        attachError = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                attachError = "Could not load the selected photo."
                isUploadingAttachment = false
                return
            }
            let fileName = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
            let response = try await apiClient.uploadFile(
                sessionName: sessionName, fileData: data, fileName: fileName, mimeType: "image/jpeg"
            )
            pendingAttachments.append(
                PendingAttachment(relayPath: response.path, displayName: fileName, warning: response.warning)
            )
            attachError = response.warning
        } catch {
            attachError = error.localizedDescription
        }
        isUploadingAttachment = false
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
                // Skip the assignment entirely when nothing actually changed —
                // on a long, mostly-idle session this poll fires every 3s
                // forever, and re-assigning an equal-but-new SessionDetail
                // still forces SwiftUI to re-diff every turn row, which was
                // re-parsing markdown (AttributedString(markdown:), not
                // cheap) for EVERY turn on EVERY poll regardless of whether
                // it changed — the real cause of "app lags on long sessions"
                // (2026-09-22). Turn/SessionDetail are both already
                // Equatable, so this is a cheap value comparison.
                if detail != self.sessionDetail {
                    self.sessionDetail = detail
                }
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
        let trimmed = inputMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // An attachment-only send (no text typed) still needs SOME text —
        // the backend requires non-empty message text regardless.
        let textToSend = trimmed.isEmpty ? "See attached file(s)." : trimmed
        let filePaths = pendingAttachments.map { $0.relayPath }

        inputMessage = ""
        pendingAttachments = []
        isSending = true

        Task {
            do {
                try await apiClient.sendMessage(sessionName: sessionName, text: textToSend, filePaths: filePaths)
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

// MARK: - Markdown rendering

private func markdownText(_ text: String) -> AttributedString {
    // Apple's Markdown parser (.full syntax) treats a bare single "\n" as an
    // insignificant soft break and drops it entirely (not even a space) —
    // confirmed live 2026-09-23: model output separated by plain newlines
    // (not blank-line paragraph breaks) rendered as running text with words
    // jammed together ("warning.Verification"). Forcing every newline into
    // a real CommonMark hard break (trailing two spaces) makes the parser
    // preserve it as a visible line break regardless of whether the source
    // used single or double newlines.
    let normalized = text.replacingOccurrences(of: "\n", with: "  \n")
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .full
    options.failurePolicy = .returnPartiallyParsedIfPossible
    guard var attributed = try? AttributedString(markdown: normalized, options: options) else {
        return AttributedString(text)
    }
    for run in attributed.runs {
        if run.link != nil {
            attributed[run.range].foregroundColor = ChatTheme.codex
        }
    }
    return attributed
}

// MARK: - Turn Row & Bubble Views

private struct ChatTurnRow: View, Equatable {
    let turn: Turn
    let isRawSnapshot: Bool
    let backendName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Old flat "Ran N commands" summary — only shown as a fallback
            // when a turn has tool_calls but no ordered `segments` (older
            // cached data, or a backend that doesn't emit segments, like
            // openrouter). Turns WITH segments render each tool inline in
            // its real position instead, which is strictly more
            // informative, so this and that are mutually exclusive.
            if turn.segments.isEmpty && !turn.toolCalls.isEmpty && turn.role != "user" {
                HStack {
                    ToolCallsSummaryRow(toolCalls: turn.toolCalls)
                    Spacer(minLength: 44)
                }
            }
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
    }

    /// Renders a turn's real content: interleaved text/tool segments in
    /// the order they actually happened, when available, or the old flat
    /// text as a fallback (no segments — older cached data, or a backend
    /// that doesn't emit them).
    @ViewBuilder
    private func turnContent(errorStyled: Bool) -> some View {
        if !turn.segments.isEmpty {
            // .textSelection(.enabled) is applied once, to this whole
            // VStack, rather than per-Text inside the loop. SwiftUI treats
            // a container carrying the modifier as ONE selection region
            // spanning all the Text views inside it, so a drag can select
            // continuously across multiple segments. Putting the modifier
            // on each small Text individually (the old code) makes every
            // segment its own isolated selection island instead.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(turn.segments) { seg in
                    if seg.type == "text", let text = seg.text, !text.isEmpty {
                        Text(markdownText(text))
                            .font(.system(size: 15))
                            .foregroundColor(errorStyled ? ChatTheme.danger : ChatTheme.textPrimary)
                            .lineSpacing(3)
                    } else if seg.type == "tool" {
                        InlineToolSegmentView(segment: seg)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            Text(markdownText(turn.text))
                .font(.system(size: 15))
                .foregroundColor(errorStyled ? ChatTheme.danger : ChatTheme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
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
                turnContent(errorStyled: false)

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

                turnContent(errorStyled: true)
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

// MARK: - "Ran N commands" summary (collapsed tool-call list per turn)

private struct ToolCallsSummaryRow: View {
    let toolCalls: [ToolCall]
    @State private var showingSheet = false

    private static let readishNames: Set<String> = [
        "view_file", "read_file", "Read", "find_by_name", "grep_search", "list_dir",
    ]

    private var label: String {
        let count = toolCalls.count
        let ranPart = count == 1 ? "Ran 1 command" : "Ran \(count) commands"
        let hasRead = toolCalls.contains { Self.readishNames.contains($0.name) }
        return hasRead ? "Read a file, \(ranPart.lowercased())" : ranPart
    }

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(ChatTheme.textDim)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSheet) {
            ToolCallsSheet(toolCalls: toolCalls)
        }
    }
}

/// A tool call rendered INLINE, in its real chronological position among
/// a turn's text segments — collapsed by default (just name + a
/// one-line summary), tap to reveal its real output. This is the
/// interleaved-order view; ToolCallRow/ToolCallsSheet below are the
/// older flat "Ran N commands" fallback for turns with no `segments`.
private struct InlineToolSegmentView: View {
    let segment: TurnSegment
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if segment.output != nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(segment.name ?? "tool")
                        .font(.system(size: 12, weight: .semibold))
                    Text(segment.summary ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if segment.output != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(ChatTheme.textDim)
            }
            .buttonStyle(.plain)

            if isExpanded, let output = segment.output {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.85))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatTheme.rawBubble)
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(ChatTheme.rawBubble.opacity(0.5))
        .cornerRadius(6)
    }
}

private struct ToolCallRow: View {
    let call: ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if call.output != nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ChatTheme.textPrimary)
                        Text(call.summary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(ChatTheme.textDim)
                            .lineLimit(isExpanded ? nil : 3)
                    }
                    .textSelection(.enabled)
                    Spacer()
                    if call.output != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ChatTheme.textDim)
                            .padding(.top, 2)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let output = call.output {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: 0.85))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatTheme.rawBubble)
                    .cornerRadius(6)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ToolCallsSheet: View {
    let toolCalls: [ToolCall]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(toolCalls) { call in
                ToolCallRow(call: call)
                    .listRowBackground(ChatTheme.cardBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("Ran \(toolCalls.count) command\(toolCalls.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                                if !freeModels.contains(where: { $0.idValue == "" }) {
                                    Text("(auto-cascade default)").tag("")
                                }
                                ForEach(freeModels) { option in
                                    Text(option.isDefault ? "\(option.label)  ★ best" : option.label)
                                        .tag(option.idValue)
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
