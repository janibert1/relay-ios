import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit

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
    static let omniroute = Color(red: 240 / 255, green: 168 / 255, blue: 75 / 255) // #f0a84b

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
        case .omniroute: return omniroute
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
    // A draft belongs to its session, not to this transient ChatView value.
    // Navigation recreates ChatView, so plain @State discarded anything the
    // user had typed when they went back to the session list.
    @SceneStorage private var inputMessage: String
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
        _inputMessage = SceneStorage(wrappedValue: "", "relay.draft.\(sessionName)")
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
            Text(sessionDetail?.displayName ?? "New conversation")
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
                                backendName: detail.backend.displayName,
                                sessionName: sessionName,
                                apiClient: apiClient
                            )
                            .id(index)
                        }

                        if !detail.queuedMessages.isEmpty {
                            ForEach(detail.queuedMessages) { message in
                                queuedMessageBubble(message)
                            }
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
                // PhotosPicker is deliberately a standalone control.  When
                // placed inside Menu, iOS 16 presents only the ordinary
                // Button children, silently dropping the PhotosPicker; that
                // made Relay look as though it supported files but not
                // photos.  Keeping both choices visible also makes the
                // distinction obvious at a glance.
                Button {
                    isShowingFileImporter = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 21))
                        .foregroundColor(ChatTheme.textDim)
                }
                .accessibilityLabel("Choose File")
                .disabled(isUploadingAttachment)

                PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 21))
                        .foregroundColor(ChatTheme.textDim)
                }
                .accessibilityLabel("Choose Photo or Video")
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
                    sendButton(isQueued: true)
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
                    sendButton(isQueued: false)
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
        return !isSending && !isUploadingAttachment && hasContent
    }

    private func sendButton(isQueued: Bool) -> some View {
        Button(action: sendMessage) {
            Image(systemName: isQueued ? "tray.and.arrow.up" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 36, height: 36)
                .background(canSend ? ChatTheme.claude : ChatTheme.claude.opacity(0.35))
                .clipShape(Circle())
        }
        .accessibilityLabel(isQueued ? "Queue message" : "Send message")
        .disabled(!canSend)
    }

    @ViewBuilder
    private func queuedMessageBubble(_ message: QueuedMessage) -> some View {
        let content = AttachmentMessageContent.parse(message.text)
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .leading, spacing: 8) {
                Label("Queued", systemImage: "clock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ChatTheme.busy)
                ForEach(content.attachments) { attachment in
                    AttachmentPreview(attachment: attachment, sessionName: sessionName, apiClient: apiClient)
                }
                if !content.body.isEmpty {
                    Text(content.body)
                        .font(.system(size: 17))
                        .foregroundColor(ChatTheme.textPrimary)
                        .lineSpacing(3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatTheme.userBubble.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChatTheme.busy.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
                attachError = "Could not load the selected photo or video."
                isUploadingAttachment = false
                return
            }
            // Data returned by PhotosPicker may be HEIC rather than JPEG.
            // Preserve the selected asset's advertised type instead of
            // labelling every byte stream as JPEG.
            let contentType = item.supportedContentTypes.first ?? .jpeg
            let fileExtension = contentType.preferredFilenameExtension ?? "jpg"
            let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
            let mediaKind = contentType.conforms(to: .movie) ? "video" : "photo"
            let fileName = "\(mediaKind)-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
            let response = try await apiClient.uploadFile(
                sessionName: sessionName, fileData: data, fileName: fileName, mimeType: mimeType
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
    // AttributedString's Markdown parser is excellent for inline styling,
    // but discards the actual newline characters around block syntax. Feed it
    // one line at a time; MarkdownTextView owns the visible block layout.
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .full
    options.failurePolicy = .returnPartiallyParsedIfPossible
    guard var attributed = try? AttributedString(markdown: text, options: options) else {
        return AttributedString(text)
    }
    for run in attributed.runs {
        if run.link != nil {
            attributed[run.range].foregroundColor = ChatTheme.codex
        }
    }
    return attributed
}

private enum MarkdownLine {
    case blank
    case text(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, label: String, text: String)
    case quote(String)
    case code(String)
    case rule
    case table(String)
    case mathBlock(String)
}

// MARK: - LaTeX Math Symbols & Functions

private let latexGreekSymbols: [String: String] = [
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
    "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
    "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
    "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
    "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
    "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
    "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
]

private let latexMathSymbols: [String: String] = [
    "times": " × ", "cdot": " · ", "div": " ÷ ", "pm": " ± ", "mp": " ∓ ",
    "le": " ≤ ", "leq": " ≤ ", "ge": " ≥ ", "geq": " ≥ ", "ne": " ≠ ", "neq": " ≠ ",
    "approx": " ≈ ", "equiv": " ≡ ", "sim": " ∼ ", "simeq": " ≃ ", "cong": " ≅ ", "propto": " ∝ ",
    "to": " → ", "rightarrow": " → ", "gets": " ← ", "leftarrow": " ← ", "leftrightarrow": " ↔ ",
    "Rightarrow": " ⇒ ", "Leftarrow": " ⇐ ", "Leftrightarrow": " ⇔ ",
    "mapsto": " ↦ ", "implies": " ⟹ ", "iff": " ⟺ ",
    "forall": "∀", "exists": "∃", "nexists": "∄", "in": " ∈ ", "notin": " ∉ ",
    "subset": " ⊂ ", "subseteq": " ⊆ ", "supset": " ⊃ ", "supseteq": " ⊇ ",
    "cap": " ∩ ", "cup": " ∪ ", "setminus": " ∖ ", "emptyset": "∅",
    "infty": "∞", "nabla": "∇", "partial": "∂",
    "sum": "∑", "prod": "∏", "coprod": "∐",
    "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
    "circ": "°", "degree": "°",
    "dots": "…", "cdots": "…", "ldots": "…", "vdots": "⋮", "ddots": "⋱",
    "vert": "|", "parallel": "∥", "perp": "⊥",
    "angle": "∠", "triangle": "△"
]

private let latexMathFunctions: Set<String> = [
    "sin", "cos", "tan", "sec", "csc", "cot",
    "sinh", "cosh", "tanh", "coth",
    "arcsin", "arccos", "arctan",
    "ln", "log", "exp", "det", "gcd", "deg",
    "min", "max", "lim", "sup", "inf", "dim", "ker"
]

private func extractBalancedBraces(from text: String, startingAt startIdx: String.Index) -> (content: String, nextIdx: String.Index)? {
    var idx = startIdx
    while idx < text.endIndex && (text[idx] == " " || text[idx] == "\t") {
        idx = text.index(after: idx)
    }
    guard idx < text.endIndex && text[idx] == "{" else { return nil }
    var depth = 1
    idx = text.index(after: idx)
    let contentStart = idx
    while idx < text.endIndex {
        if text[idx] == "\\" {
            idx = text.index(after: idx)
            if idx < text.endIndex { idx = text.index(after: idx) }
            continue
        }
        if text[idx] == "{" {
            depth += 1
        } else if text[idx] == "}" {
            depth -= 1
            if depth == 0 {
                return (String(text[contentStart..<idx]), text.index(after: idx))
            }
        }
        idx = text.index(after: idx)
    }
    return (String(text[contentStart...]), text.endIndex)
}

private func parseLaTeXTokens(
    _ text: String,
    baseSize: CGFloat,
    textColor: UIColor,
    isSubscript: Bool,
    isSuperscript: Bool,
    to result: NSMutableAttributedString
) {
    var idx = text.startIndex

    func appendPiece(
        _ str: String,
        font: UIFont,
        color: UIColor = textColor,
        baselineOffset: CGFloat? = nil
    ) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if let offset = baselineOffset {
            attrs[.baselineOffset] = offset
        } else if isSubscript {
            attrs[.baselineOffset] = -baseSize * 0.22
        } else if isSuperscript {
            attrs[.baselineOffset] = baseSize * 0.38
        }
        result.append(NSAttributedString(string: str, attributes: attrs))
    }

    while idx < text.endIndex {
        let ch = text[idx]

        // 1. Space
        if ch == " " || ch == "\t" {
            appendPiece(" ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }

        // 2. Backslash command
        if ch == "\\" {
            let afterSlash = text.index(after: idx)
            guard afterSlash < text.endIndex else { break }

            let nextCh = text[afterSlash]
            // Non-alpha commands like \, \; \{ \} \\
            if !nextCh.isLetter {
                idx = text.index(after: afterSlash)
                switch nextCh {
                case ",", ";", " ":
                    appendPiece(" ", font: UIFont.systemFont(ofSize: baseSize))
                case "{":
                    appendPiece("{", font: UIFont.systemFont(ofSize: baseSize))
                case "}":
                    appendPiece("}", font: UIFont.systemFont(ofSize: baseSize))
                case "\\":
                    appendPiece("\n", font: UIFont.systemFont(ofSize: baseSize))
                case "|":
                    appendPiece("|", font: UIFont.systemFont(ofSize: baseSize))
                default:
                    appendPiece(String(nextCh), font: UIFont.systemFont(ofSize: baseSize))
                }
                continue
            }

            // Alpha command: extract command name
            var cmdEnd = afterSlash
            while cmdEnd < text.endIndex && text[cmdEnd].isLetter {
                cmdEnd = text.index(after: cmdEnd)
            }
            let cmd = String(text[afterSlash..<cmdEnd])
            idx = cmdEnd

            switch cmd {
            case "text", "mathrm", "operatorname", "mbox", "textnormal", "textrm":
                if let (content, next) = extractBalancedBraces(from: text, startingAt: idx) {
                    appendPiece(content, font: UIFont.systemFont(ofSize: baseSize, weight: .regular))
                    idx = next
                } else {
                    appendPiece(cmd, font: UIFont.systemFont(ofSize: baseSize))
                }

            case "textbf", "mathbf":
                if let (content, next) = extractBalancedBraces(from: text, startingAt: idx) {
                    appendPiece(content, font: UIFont.systemFont(ofSize: baseSize, weight: .bold))
                    idx = next
                } else {
                    appendPiece(cmd, font: UIFont.systemFont(ofSize: baseSize, weight: .bold))
                }

            case "textit", "mathit":
                if let (content, next) = extractBalancedBraces(from: text, startingAt: idx) {
                    appendPiece(content, font: UIFont.italicSystemFont(ofSize: baseSize))
                    idx = next
                } else {
                    appendPiece(cmd, font: UIFont.italicSystemFont(ofSize: baseSize))
                }

            case "frac", "dfrac":
                if let (num, next1) = extractBalancedBraces(from: text, startingAt: idx),
                   let (den, next2) = extractBalancedBraces(from: text, startingAt: next1) {
                    let numPiece = NSMutableAttributedString()
                    parseLaTeXTokens(num, baseSize: baseSize, textColor: textColor, isSubscript: isSubscript, isSuperscript: isSuperscript, to: numPiece)
                    let denPiece = NSMutableAttributedString()
                    parseLaTeXTokens(den, baseSize: baseSize, textColor: textColor, isSubscript: isSubscript, isSuperscript: isSuperscript, to: denPiece)

                    result.append(numPiece)
                    appendPiece(" / ", font: UIFont.systemFont(ofSize: baseSize))
                    result.append(denPiece)
                    idx = next2
                }

            case "sqrt":
                var rootIndex: String? = nil
                var scanIdx = idx
                while scanIdx < text.endIndex && text[scanIdx].isWhitespace {
                    scanIdx = text.index(after: scanIdx)
                }
                if scanIdx < text.endIndex && text[scanIdx] == "[" {
                    if let closeBracket = text[scanIdx...].firstIndex(of: "]") {
                        rootIndex = String(text[text.index(after: scanIdx)..<closeBracket])
                        scanIdx = text.index(after: closeBracket)
                    }
                }
                if let (body, next) = extractBalancedBraces(from: text, startingAt: scanIdx) {
                    if let root = rootIndex {
                        let rootPiece = NSMutableAttributedString()
                        parseLaTeXTokens(root, baseSize: baseSize * 0.72, textColor: textColor, isSubscript: false, isSuperscript: true, to: rootPiece)
                        result.append(rootPiece)
                    }
                    appendPiece("√(", font: UIFont.systemFont(ofSize: baseSize))
                    parseLaTeXTokens(body, baseSize: baseSize, textColor: textColor, isSubscript: isSubscript, isSuperscript: isSuperscript, to: result)
                    appendPiece(")", font: UIFont.systemFont(ofSize: baseSize))
                    idx = next
                }

            case "quad":
                appendPiece("   ", font: UIFont.systemFont(ofSize: baseSize))
            case "qquad":
                appendPiece("      ", font: UIFont.systemFont(ofSize: baseSize))
            case "left", "right":
                if idx < text.endIndex && text[idx] == "." {
                    idx = text.index(after: idx)
                }

            default:
                if let greek = latexGreekSymbols[cmd] {
                    appendPiece(greek, font: UIFont.systemFont(ofSize: baseSize))
                } else if let op = latexMathSymbols[cmd] {
                    appendPiece(op, font: UIFont.systemFont(ofSize: baseSize))
                } else if latexMathFunctions.contains(cmd) {
                    appendPiece(cmd + " ", font: UIFont.systemFont(ofSize: baseSize))
                } else {
                    appendPiece(cmd, font: UIFont.systemFont(ofSize: baseSize))
                }
            }
            continue
        }

        // 3. Subscript _
        if ch == "_" {
            let afterUnderscore = text.index(after: idx)
            guard afterUnderscore < text.endIndex else {
                idx = text.index(after: idx)
                continue
            }
            if text[afterUnderscore] == "{" {
                if let (content, next) = extractBalancedBraces(from: text, startingAt: afterUnderscore) {
                    parseLaTeXTokens(content, baseSize: baseSize * 0.72, textColor: textColor, isSubscript: true, isSuperscript: false, to: result)
                    idx = next
                    continue
                }
            } else if text[afterUnderscore] == "\\" {
                idx = afterUnderscore
                let afterSlash = text.index(after: idx)
                var cmdEnd = afterSlash
                while cmdEnd < text.endIndex && text[cmdEnd].isLetter {
                    cmdEnd = text.index(after: cmdEnd)
                }
                let subCmd = String(text[afterSlash..<cmdEnd])
                idx = cmdEnd
                let symbol = latexGreekSymbols[subCmd] ?? latexMathSymbols[subCmd] ?? subCmd
                appendPiece(symbol, font: UIFont.systemFont(ofSize: baseSize * 0.72), baselineOffset: -baseSize * 0.22)
                continue
            } else {
                let singleChar = String(text[afterUnderscore])
                let isLetter = text[afterUnderscore].isLetter
                let font = isLetter ? UIFont.italicSystemFont(ofSize: baseSize * 0.72) : UIFont.systemFont(ofSize: baseSize * 0.72)
                appendPiece(singleChar, font: font, baselineOffset: -baseSize * 0.22)
                idx = text.index(after: afterUnderscore)
                continue
            }
        }

        // 4. Superscript ^
        if ch == "^" {
            let afterCaret = text.index(after: idx)
            guard afterCaret < text.endIndex else {
                idx = text.index(after: idx)
                continue
            }
            if text[afterCaret] == "{" {
                if let (content, next) = extractBalancedBraces(from: text, startingAt: afterCaret) {
                    if content == "\\circ" || content == "\\circ{C}" || content == "\\degree" {
                        appendPiece("°C", font: UIFont.systemFont(ofSize: baseSize))
                    } else {
                        parseLaTeXTokens(content, baseSize: baseSize * 0.72, textColor: textColor, isSubscript: false, isSuperscript: true, to: result)
                    }
                    idx = next
                    continue
                }
            } else if text[afterCaret] == "\\" {
                idx = afterCaret
                let afterSlash = text.index(after: idx)
                var cmdEnd = afterSlash
                while cmdEnd < text.endIndex && text[cmdEnd].isLetter {
                    cmdEnd = text.index(after: cmdEnd)
                }
                let supCmd = String(text[afterSlash..<cmdEnd])
                idx = cmdEnd
                if supCmd == "circ" || supCmd == "degree" {
                    appendPiece("°", font: UIFont.systemFont(ofSize: baseSize))
                } else {
                    let symbol = latexGreekSymbols[supCmd] ?? latexMathSymbols[supCmd] ?? supCmd
                    appendPiece(symbol, font: UIFont.systemFont(ofSize: baseSize * 0.72), baselineOffset: baseSize * 0.38)
                }
                continue
            } else {
                let singleChar = String(text[afterCaret])
                let isLetter = text[afterCaret].isLetter
                let font = isLetter ? UIFont.italicSystemFont(ofSize: baseSize * 0.72) : UIFont.systemFont(ofSize: baseSize * 0.72)
                appendPiece(singleChar, font: font, baselineOffset: baseSize * 0.38)
                idx = text.index(after: afterCaret)
                continue
            }
        }

        // 5. Minus sign
        if ch == "-" {
            let prevChar = idx > text.startIndex ? text[text.index(before: idx)] : nil
            let nextIdx = text.index(after: idx)
            let nextChar = nextIdx < text.endIndex ? text[nextIdx] : nil
            if prevChar == nil || prevChar == "=" || prevChar == "(" || prevChar == "[" || prevChar == " " {
                appendPiece("−", font: UIFont.systemFont(ofSize: baseSize))
            } else if nextChar == " " || prevChar == " " {
                appendPiece("−", font: UIFont.systemFont(ofSize: baseSize))
            } else {
                appendPiece(" − ", font: UIFont.systemFont(ofSize: baseSize))
            }
            idx = text.index(after: idx)
            continue
        }

        // 6. Plus, Equals, Relations
        if ch == "+" {
            appendPiece(" + ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }
        if ch == "=" {
            appendPiece(" = ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }
        if ch == "<" {
            appendPiece(" < ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }
        if ch == ">" {
            appendPiece(" > ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }
        if ch == "*" {
            appendPiece(" · ", font: UIFont.systemFont(ofSize: baseSize))
            idx = text.index(after: idx)
            continue
        }

        // 7. Single Latin letters (Variables)
        if ch.isLetter && ch.isASCII {
            let font = UIFont.italicSystemFont(ofSize: baseSize)
            appendPiece(String(ch), font: font)
            idx = text.index(after: idx)
            continue
        }

        // 8. Digits
        if ch.isNumber {
            var numEnd = idx
            while numEnd < text.endIndex && (text[numEnd].isNumber || text[numEnd] == ".") {
                numEnd = text.index(after: numEnd)
            }
            let numStr = String(text[idx..<numEnd])
            appendPiece(numStr, font: UIFont.systemFont(ofSize: baseSize))
            idx = numEnd
            continue
        }

        // 9. Other punctuation / symbols
        appendPiece(String(ch), font: UIFont.systemFont(ofSize: baseSize))
        idx = text.index(after: idx)
    }
}

private func renderLaTeXMath(
    _ latex: String,
    isDisplayMode: Bool,
    textColor: UIColor,
    baseSize: CGFloat = 17
) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return result }

    parseLaTeXTokens(
        trimmed,
        baseSize: baseSize,
        textColor: textColor,
        isSubscript: false,
        isSuperscript: false,
        to: result
    )

    if isDisplayMode {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 10
        style.paragraphSpacingBefore = 10
        style.lineSpacing = 4
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
    }

    return result
}

private enum InlineSegment {
    case text(String)
    case inlineMath(String)
    case displayMath(String)
}

private func splitInlineMathSegments(_ text: String) -> [InlineSegment] {
    var segments: [InlineSegment] = []
    var currentText = ""
    var idx = text.startIndex

    while idx < text.endIndex {
        // 1. Check for $$ display math
        if text[idx...].hasPrefix("$$") {
            let searchStart = text.index(idx, offsetBy: 2)
            if let closingRange = text[searchStart...].range(of: "$$") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                let math = String(text[searchStart..<closingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                segments.append(.displayMath(math))
                idx = closingRange.upperBound
                continue
            }
        }

        // 2. Check for \[ display math
        if text[idx...].hasPrefix("\\[") {
            let searchStart = text.index(idx, offsetBy: 2)
            if let closingRange = text[searchStart...].range(of: "\\]") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                let math = String(text[searchStart..<closingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                segments.append(.displayMath(math))
                idx = closingRange.upperBound
                continue
            }
        }

        // 3. Check for \( inline math
        if text[idx...].hasPrefix("\\(") {
            let searchStart = text.index(idx, offsetBy: 2)
            if let closingRange = text[searchStart...].range(of: "\\)") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                let math = String(text[searchStart..<closingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                segments.append(.inlineMath(math))
                idx = closingRange.upperBound
                continue
            }
        }

        // 4. Check for $ inline math
        if text[idx] == "$" {
            if idx > text.startIndex && text[text.index(before: idx)] == "\\" {
                currentText.append("$")
                idx = text.index(after: idx)
                continue
            }
            let afterDollar = text.index(after: idx)
            if afterDollar < text.endIndex {
                let nextChar = text[afterDollar]
                if nextChar != " " && nextChar != "\t" && nextChar != "\n" && nextChar != "$" {
                    var search = afterDollar
                    var foundClosing: String.Index? = nil
                    while search < text.endIndex {
                        let c = text[search]
                        if c == "\n" { break }
                        if c == "$" {
                            let prev = text[text.index(before: search)]
                            if prev != "\\" && prev != " " && prev != "\t" {
                                foundClosing = search
                                break
                            }
                        }
                        search = text.index(after: search)
                    }

                    if let closingIdx = foundClosing {
                        let candidate = String(text[afterDollar..<closingIdx])
                        let isCurrency = candidate.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "k" || $0 == "M" }
                        if !isCurrency {
                            if !currentText.isEmpty {
                                segments.append(.text(currentText))
                                currentText = ""
                            }
                            segments.append(.inlineMath(candidate.trimmingCharacters(in: .whitespaces)))
                            idx = text.index(after: closingIdx)
                            continue
                        }
                    }
                }
            }
        }

        currentText.append(text[idx])
        idx = text.index(after: idx)
    }

    if !currentText.isEmpty {
        segments.append(.text(currentText))
    }
    return segments
}

/// A block-aware Markdown renderer. Apple's AttributedString strips the
/// newline characters around headers/lists/quotes ("# Header\n\nText" becomes
/// "HeaderText"), so a single Text view can never lay those blocks out
/// correctly. This view keeps each source line as a real SwiftUI row and
/// uses AttributedString only for inline formatting within that row.
private struct MarkdownTextView: View {
    let text: String
    let textColor: UIColor

    var body: some View {
        SelectableMarkdownTextView(attributedText: renderedText, textColor: textColor)
    }

    private var lines: [MarkdownLine] {
        var result: [MarkdownLine] = []
        var inCodeFence = false
        var inMathFence = false
        var currentMathLines: [String] = []

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                result.append(.code(rawLine))
                continue
            }

            if inMathFence {
                if trimmed == "$$" || trimmed.hasSuffix("$$") || trimmed == "\\]" || trimmed.hasSuffix("\\]") {
                    let endStripped: String
                    if trimmed.hasSuffix("$$") {
                        endStripped = String(trimmed.dropLast(2))
                    } else if trimmed.hasSuffix("\\]") {
                        endStripped = String(trimmed.dropLast(2))
                    } else {
                        endStripped = ""
                    }
                    let clean = endStripped.trimmingCharacters(in: .whitespaces)
                    if !clean.isEmpty {
                        currentMathLines.append(clean)
                    }
                    inMathFence = false
                    let mathBody = currentMathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !mathBody.isEmpty {
                        result.append(.mathBlock(mathBody))
                    }
                    currentMathLines = []
                } else {
                    currentMathLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("$$") {
                if trimmed.count > 2 && trimmed.dropFirst(2).hasSuffix("$$") {
                    let math = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    result.append(.mathBlock(math))
                    continue
                } else {
                    inMathFence = true
                    let rem = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty {
                        currentMathLines.append(rem)
                    }
                    continue
                }
            } else if trimmed.hasPrefix("\\[") {
                if trimmed.count > 2 && trimmed.dropFirst(2).hasSuffix("\\]") {
                    let math = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    result.append(.mathBlock(math))
                    continue
                } else {
                    inMathFence = true
                    let rem = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty {
                        currentMathLines.append(rem)
                    }
                    continue
                }
            }

            if trimmed.isEmpty {
                result.append(.blank)
            } else if let heading = heading(from: trimmed) {
                result.append(heading)
            } else if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                result.append(.rule)
            } else if trimmed.hasPrefix(">") {
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let numbered = numberedLine(from: trimmed, indent: indentation(of: rawLine)) {
                result.append(numbered)
            } else if let bullet = bulletLine(from: trimmed, indent: indentation(of: rawLine)) {
                result.append(bullet)
            } else if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                result.append(.table(trimmed))
            } else {
                result.append(.text(rawLine))
            }
        }
        if inMathFence && !currentMathLines.isEmpty {
            result.append(.mathBlock(currentMathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }

    private func heading(from line: String) -> MarkdownLine? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6,
              line.dropFirst(hashes.count).first == " " else { return nil }
        return .heading(
            level: hashes.count,
            text: String(line.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
        )
    }

    private func bulletLine(from line: String, indent: Int) -> MarkdownLine? {
        guard line.count >= 2,
              ["-", "*", "+"].contains(line.first.map(String.init) ?? ""),
              line.dropFirst().first == " " else { return nil }
        return .bullet(indent: indent, text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private func numberedLine(from line: String, indent: Int) -> MarkdownLine? {
        guard let range = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) else { return nil }
        let label = String(line[range]).trimmingCharacters(in: .whitespaces)
        return .numbered(
            indent: indent,
            label: label,
            text: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count / 2
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: textColor,
        ]
    }

    private var renderedText: NSAttributedString {
        let result = NSMutableAttributedString()
        for line in lines {
            append(line, to: result)
        }
        return result
    }

    private func append(_ line: MarkdownLine, to result: NSMutableAttributedString) {
        switch line {
        case .blank:
            appendRaw("\n", to: result)
        case .text(let value):
            appendInline(value, to: result)
            appendRaw("\n", to: result)
        case .mathBlock(let value):
            appendRaw("\n", to: result)
            let mathAttr = renderLaTeXMath(value, isDisplayMode: true, textColor: textColor, baseSize: 18)
            result.append(mathAttr)
            appendRaw("\n\n", to: result)
        case .heading(let level, let value):
            let start = result.length
            appendInline(value, to: result)
            result.addAttribute(
                .font,
                value: UIFont.systemFont(ofSize: level == 1 ? 21 : level == 2 ? 18 : 16, weight: .bold),
                range: NSRange(location: start, length: result.length - start)
            )
            appendRaw("\n\n", to: result)
        case .bullet(let indent, let value):
            appendRaw(String(repeating: "  ", count: indent) + "• ", to: result)
            appendInline(value, to: result)
            appendRaw("\n", to: result)
        case .numbered(let indent, let label, let value):
            appendRaw(String(repeating: "  ", count: indent) + "\(label) ", to: result)
            appendInline(value, to: result)
            appendRaw("\n", to: result)
        case .quote(let value):
            appendRaw("▎ ", to: result, color: UIColor(ChatTheme.textDim))
            appendInline(value, to: result)
            appendRaw("\n", to: result)
        case .code(let value):
            appendRaw(
                value.isEmpty ? " " : value,
                to: result,
                font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            )
            appendRaw("\n", to: result)
        case .rule:
            appendRaw("────────────────\n", to: result, color: UIColor(ChatTheme.border))
        case .table(let value):
            appendRaw(
                "\(value)\n",
                to: result,
                font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            )
        }
    }

    private func applyRelayInlineStyling(to inline: NSMutableAttributedString, baseSize: CGFloat, defaultColor: UIColor) {
        inline.enumerateAttribute(.font, in: NSRange(location: 0, length: inline.length)) { fontObj, range, _ in
            if let font = fontObj as? UIFont {
                let descriptor = font.fontDescriptor
                let isBold = descriptor.symbolicTraits.contains(.traitBold)
                let isItalic = descriptor.symbolicTraits.contains(.traitItalic)
                let isMono = descriptor.symbolicTraits.contains(.traitMonoSpace)

                let targetFont: UIFont
                if isMono {
                    targetFont = UIFont.monospacedSystemFont(ofSize: max(12, baseSize - 2), weight: isBold ? .bold : .regular)
                } else if isBold && isItalic {
                    let base = UIFont.systemFont(ofSize: baseSize, weight: .bold)
                    if let sym = base.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                        targetFont = UIFont(descriptor: sym, size: baseSize)
                    } else {
                        targetFont = base
                    }
                } else if isBold {
                    targetFont = UIFont.systemFont(ofSize: baseSize, weight: .bold)
                } else if isItalic {
                    targetFont = UIFont.italicSystemFont(ofSize: baseSize)
                } else {
                    targetFont = UIFont.systemFont(ofSize: baseSize)
                }
                inline.addAttribute(.font, value: targetFont, range: range)
            } else {
                inline.addAttribute(.font, value: UIFont.systemFont(ofSize: baseSize), range: range)
            }
        }

        inline.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: inline.length)) { colorObj, range, _ in
            if colorObj == nil {
                inline.addAttribute(.foregroundColor, value: defaultColor, range: range)
            }
        }
    }

    private func appendInline(_ value: String, to result: NSMutableAttributedString) {
        let segments = splitInlineMathSegments(value)
        for segment in segments {
            switch segment {
            case .text(let text):
                let inline = NSMutableAttributedString(attributedString: NSAttributedString(markdownText(text)))
                applyRelayInlineStyling(to: inline, baseSize: 17, defaultColor: textColor)
                result.append(inline)
            case .inlineMath(let math):
                let mathAttr = renderLaTeXMath(math, isDisplayMode: false, textColor: textColor, baseSize: 17)
                result.append(mathAttr)
            case .displayMath(let math):
                appendRaw("\n", to: result)
                let mathAttr = renderLaTeXMath(math, isDisplayMode: true, textColor: textColor, baseSize: 18)
                result.append(mathAttr)
                appendRaw("\n", to: result)
            }
        }
    }

    private func appendRaw(
        _ value: String,
        to result: NSMutableAttributedString,
        color: UIColor? = nil,
        font: UIFont? = nil
    ) {
        var attributes = baseAttributes
        if let color { attributes[.foregroundColor] = color }
        if let font { attributes[.font] = font }
        result.append(NSAttributedString(string: value, attributes: attributes))
    }
}

private struct SelectableMarkdownTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let textColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = [.link]
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textColor = textColor
        textView.attributedText = attributedText
        textView.linkTextAttributes = [.foregroundColor: UIColor(ChatTheme.codex)]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

// MARK: - Turn Row & Bubble Views

/// The API places uploaded files at the start of the sent text so every
/// provider receives a plain, useful path.  The native client recognises that
/// small envelope again to render media rather than exposing implementation
/// text to the person who sent it.
private struct AttachmentMessageContent {
    let attachments: [RelayAttachment]
    let body: String

    static func parse(_ text: String) -> AttachmentMessageContent {
        let prefix = "[Attached file(s): "
        guard text.hasPrefix(prefix), let markerEnd = text.range(of: "]\n\n") else {
            return AttachmentMessageContent(attachments: [], body: text)
        }

        let pathsStart = text.index(text.startIndex, offsetBy: prefix.count)
        let pathList = String(text[pathsStart..<markerEnd.lowerBound])
        let paths = pathList.components(separatedBy: ", ").filter { !$0.isEmpty }
        let body = String(text[markerEnd.upperBound...])
        return AttachmentMessageContent(
            attachments: paths.map(RelayAttachment.init(relayPath:)),
            body: body
        )
    }
}

private struct RelayAttachment: Identifiable {
    let relayPath: String

    var id: String { relayPath }
    var displayName: String { URL(fileURLWithPath: relayPath).lastPathComponent }

    private var fileExtension: String {
        URL(fileURLWithPath: relayPath).pathExtension.lowercased()
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(fileExtension)
    }

    var isVideo: Bool {
        ["mp4", "mov", "m4v", "avi", "webm", "mpg", "mpeg"].contains(fileExtension)
    }
}

private struct AttachmentPreview: View {
    let attachment: RelayAttachment
    let sessionName: String
    let apiClient: RelayAPIClient

    var body: some View {
        if attachment.isImage {
            RemoteAttachmentImage(
                attachment: attachment,
                sessionName: sessionName,
                apiClient: apiClient
            )
        } else if attachment.isVideo {
            RemoteAttachmentVideo(
                attachment: attachment,
                sessionName: sessionName,
                apiClient: apiClient
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18))
                    Text(attachment.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                }
                AttachmentDownloadButton(attachment: attachment, sessionName: sessionName, apiClient: apiClient)
            }
            .foregroundColor(ChatTheme.textPrimary)
            .padding(10)
            .background(ChatTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct RemoteAttachmentImage: View {
    let attachment: RelayAttachment
    let sessionName: String
    let apiClient: RelayAPIClient

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var isPresentingImageViewer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button {
                    isPresentingImageViewer = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.62), in: Circle())
                            .padding(9)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(attachment.displayName) full screen")
            } else if loadFailed {
                unavailableMediaLabel(icon: "photo")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 96)
            }

            Text(attachment.displayName)
                .font(.system(size: 12))
                .foregroundColor(ChatTheme.textDim)
                .lineLimit(1)

            AttachmentDownloadButton(attachment: attachment, sessionName: sessionName, apiClient: apiClient)
        }
        .task(id: attachment.relayPath) {
            do {
                let data = try await apiClient.downloadFile(sessionName: sessionName, relayPath: attachment.relayPath)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
                loadFailed = image == nil
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
        .fullScreenCover(isPresented: $isPresentingImageViewer) {
            if let image {
                AttachmentImageViewer(image: image, title: attachment.displayName)
            }
        }
    }
}

private struct AttachmentImageViewer: View {
    let image: UIImage
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZoomableAttachmentImage(image: image)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel("Close image")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                Text("Pinch or double-tap to zoom")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.54), in: Capsule())
                    .padding(.bottom, 30)
            }
            .foregroundStyle(.white)
        }
    }
}

private struct ZoomableAttachmentImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.image = image
        DispatchQueue.main.async {
            context.coordinator.layoutImage(in: scrollView)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var image: UIImage
        weak var imageView: UIImageView?
        private var imageSize: CGSize = .zero
        private var viewSize: CGSize = .zero

        init(image: UIImage) {
            self.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let zoomScale = min(2.5, scrollView.maximumZoomScale)
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: scrollView.bounds.width / zoomScale,
                height: scrollView.bounds.height / zoomScale
            )
            scrollView.zoom(to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ), animated: true)
        }

        func layoutImage(in scrollView: UIScrollView) {
            guard let imageView, scrollView.bounds.size != .zero else { return }
            guard imageSize != image.size || viewSize != scrollView.bounds.size else { return }

            imageSize = image.size
            viewSize = scrollView.bounds.size
            imageView.image = image
            let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            centerImage(in: scrollView)
        }

        private func centerImage(in scrollView: UIScrollView) {
            let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }
}

private struct RemoteAttachmentVideo: View {
    let attachment: RelayAttachment
    let sessionName: String
    let apiClient: RelayAPIClient

    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onDisappear { player.pause() }
            } else if loadFailed {
                unavailableMediaLabel(icon: "video")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            }

            Text(attachment.displayName)
                .font(.system(size: 12))
                .foregroundColor(ChatTheme.textDim)
                .lineLimit(1)

            AttachmentDownloadButton(attachment: attachment, sessionName: sessionName, apiClient: apiClient)
        }
        .task(id: attachment.relayPath) {
            do {
                let data = try await apiClient.downloadFile(sessionName: sessionName, relayPath: attachment.relayPath)
                guard !Task.isCancelled else { return }
                let ext = URL(fileURLWithPath: attachment.relayPath).pathExtension
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-\(UUID().uuidString).\(ext)")
                try data.write(to: url, options: .atomic)
                player = AVPlayer(url: url)
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }
}

/// Downloads to Relay's local temporary store and opens iOS's share sheet,
/// whose standard "Save to Files" action makes this a real user-controlled
/// download rather than an inaccessible sandbox copy.
private struct AttachmentDownloadButton: View {
    let attachment: RelayAttachment
    let sessionName: String
    let apiClient: RelayAPIClient

    @State private var downloadedURL: URL?
    @State private var isDownloading = false
    @State private var failed = false

    var body: some View {
        if let downloadedURL {
            ShareLink(item: downloadedURL) {
                Label("Save file", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(ChatTheme.codex)
        } else {
            Button {
                Task { await download() }
            } label: {
                if isDownloading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Label(failed ? "Try download again" : "Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundColor(failed ? ChatTheme.danger : ChatTheme.codex)
            .disabled(isDownloading)
        }
    }

    @MainActor
    private func download() async {
        isDownloading = true
        failed = false
        do {
            let data = try await apiClient.downloadFile(sessionName: sessionName, relayPath: attachment.relayPath)
            let safeName = attachment.displayName.isEmpty ? "relay-download" : attachment.displayName
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)-\(safeName)")
            try data.write(to: url, options: .atomic)
            downloadedURL = url
        } catch {
            failed = true
        }
        isDownloading = false
    }
}

@ViewBuilder
private func unavailableMediaLabel(icon: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "\(icon).slash")
        Text("Attachment is no longer available")
            .font(.system(size: 13))
    }
    .foregroundColor(ChatTheme.textDim)
    .frame(maxWidth: .infinity, minHeight: 72)
    .background(ChatTheme.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private struct ChatTurnRow: View {
    let turn: Turn
    let isRawSnapshot: Bool
    let backendName: String
    let sessionName: String
    let apiClient: RelayAPIClient

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
            // Text segments use UITextView internally for real native range
            // selection. Tool rows retain their own tap/expand behaviour.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(turn.segments) { seg in
                    if seg.type == "text", let text = seg.text, !text.isEmpty {
                        assistantTextSegment(text, errorStyled: errorStyled)
                    } else if seg.type == "tool" {
                        InlineToolSegmentView(segment: seg)
                    }
                }
            }
        } else {
            assistantTextSegment(turn.text, errorStyled: errorStyled)
        }
    }

    @ViewBuilder
    private func assistantTextSegment(_ text: String, errorStyled: Bool) -> some View {
        let content = AttachmentMessageContent.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(content.attachments) { attachment in
                AttachmentPreview(attachment: attachment, sessionName: sessionName, apiClient: apiClient)
            }
            if !content.body.isEmpty {
                MarkdownTextView(
                    text: content.body,
                    textColor: UIColor(errorStyled ? ChatTheme.danger : ChatTheme.textPrimary)
                )
            }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        let content = AttachmentMessageContent.parse(turn.text)
        HStack {
            Spacer(minLength: 44)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(content.attachments) { attachment in
                    AttachmentPreview(
                        attachment: attachment,
                        sessionName: sessionName,
                        apiClient: apiClient
                    )
                }

                if !content.body.isEmpty {
                    Text(content.body)
                        .font(.system(size: 17))
                        .foregroundColor(ChatTheme.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
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
