import SwiftUI

/// Sheet for creating a new Relay session.
/// Supports choosing between Claude, Codex, and Gemini backends,
/// validating session names, configuring optional working directory,
/// dynamic model selection per backend, and optional effort level.
struct NewSessionSheet: View {
    let apiClient: RelayAPIClient
    var onCreated: ((SessionSummary) -> Void)?

    @Environment(\.dismiss) private var dismiss

    // MARK: - Form State

    @State private var selectedBackend: BackendId = .claude
    @State private var name: String = ""
    @State private var cwd: String = ""
    @State private var selectedModel: String = ""
    @State private var selectedEffort: String = ""

    // MARK: - Network & Loading State

    @State private var models: [ModelOption] = []
    @State private var isLoadingModels: Bool = false
    @State private var modelLoadError: String? = nil

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: - Constants

    private let availableBackends: [BackendId] = [.claude, .codex, .gemini]

    private let effortOptions: [(value: String, label: String)] = [
        ("", "default"),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max")
    ]

    // MARK: - Color Palette (Hardcoded Dark Theme)

    private let backgroundColor = Color(red: 0.039, green: 0.039, blue: 0.039)       // #0a0a0a
    private let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)        // #1a1a1a
    private let cardBorder = Color(red: 0.165, green: 0.165, blue: 0.165)            // #2a2a2a
    private let primaryTextColor = Color(red: 0.949, green: 0.949, blue: 0.949)      // #f2f2f2
    private let dimTextColor = Color(red: 0.541, green: 0.541, blue: 0.541)          // #8a8a8a
    private let dangerColor = Color(red: 1.0, green: 0.420, blue: 0.420)             // #ff6b6b

    init(
        apiClient: RelayAPIClient = .shared,
        onCreated: ((SessionSummary) -> Void)? = nil
    ) {
        self.apiClient = apiClient
        self.onCreated = onCreated
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let errorMessage {
                        errorBanner(message: errorMessage)
                    }

                    backendSection

                    nameSection

                    cwdSection

                    configurationSection

                    submitButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(backgroundColor.ignoresSafeArea())
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(dimTextColor)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await submitSession()
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(canSubmit ? currentAccentColor : dimTextColor.opacity(0.4))
                    .disabled(!canSubmit)
                }
            }
            .task(id: selectedBackend) {
                await loadModels(for: selectedBackend)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKEND")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(dimTextColor)
                .tracking(0.5)

            Picker("Backend", selection: $selectedBackend) {
                ForEach(availableBackends, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(currentAccentColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)

                Text("Backend is locked in once created — you can change model any time, and can always drop down to a free OpenRouter model later, but never back up to a paid backend.")
                    .font(.system(size: 12))
                    .foregroundColor(dimTextColor)
                    .lineSpacing(2)
            }
            .padding(.top, 2)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NAME")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(dimTextColor)
                    .tracking(0.5)
                Spacer()
                if isNameFormatValid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.290, green: 0.871, blue: 0.502))
                }
            }

            TextField("e.g. my-task", text: $name)
                .font(.system(size: 16))
                .foregroundColor(primaryTextColor)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(cardBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(nameValidationError != nil ? dangerColor : cardBorder, lineWidth: 1)
                )

            if let validationError = nameValidationError {
                Text(validationError)
                    .font(.system(size: 12))
                    .foregroundColor(dangerColor)
            }
        }
    }

    private var cwdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WORKING DIRECTORY")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(dimTextColor)
                    .tracking(0.5)

                Spacer()

                Text("optional")
                    .font(.system(size: 11))
                    .foregroundColor(dimTextColor)
            }

            TextField("/home/jan/...", text: $cwd)
                .font(.system(size: 16))
                .foregroundColor(primaryTextColor)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(cardBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cardBorder, lineWidth: 1)
                )
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIGURATION")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(dimTextColor)
                .tracking(0.5)

            VStack(spacing: 0) {
                // Model Picker Row
                HStack {
                    Text("Model")
                        .font(.system(size: 16))
                        .foregroundColor(primaryTextColor)

                    Spacer()

                    if isLoadingModels {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            Text("(default)").tag("")
                            ForEach(models) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(currentAccentColor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()
                    .background(cardBorder)
                    .padding(.horizontal, 14)

                // Effort Picker Row
                HStack {
                    HStack(spacing: 6) {
                        Text("Effort")
                            .font(.system(size: 16))
                            .foregroundColor(primaryTextColor)

                        Text("optional")
                            .font(.system(size: 11))
                            .foregroundColor(dimTextColor)
                    }

                    Spacer()

                    Picker("Effort", selection: $selectedEffort) {
                        ForEach(effortOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(currentAccentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cardBorder, lineWidth: 1)
            )

            if let modelLoadError {
                HStack(spacing: 6) {
                    Text("Could not load model list: \(modelLoadError)")
                        .font(.system(size: 12))
                        .foregroundColor(dimTextColor)
                    Spacer()
                    Button("Retry") {
                        Task {
                            await loadModels(for: selectedBackend)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(currentAccentColor)
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var submitButton: some View {
        Button {
            Task {
                await submitSession()
            }
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                }
                Text(isSubmitting ? "Creating…" : "Create Session")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(canSubmit ? currentAccentColor : currentAccentColor.opacity(0.35))
            .cornerRadius(12)
        }
        .disabled(!canSubmit)
        .padding(.top, 8)
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(dangerColor)
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(dangerColor)
                .multilineTextAlignment(.leading)

            Spacer()
        }
        .padding(12)
        .background(dangerColor.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(dangerColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Validation & Helpers

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNameFormatValid: Bool {
        guard !trimmedName.isEmpty else { return false }
        let pattern = "^[a-zA-Z0-9_-]+$"
        return trimmedName.range(of: pattern, options: .regularExpression) != nil
    }

    private var nameValidationError: String? {
        if trimmedName.isEmpty {
            return nil
        }
        if !isNameFormatValid {
            return "Name must be letters, digits, - and _ only."
        }
        return nil
    }

    private var canSubmit: Bool {
        isNameFormatValid && !isSubmitting
    }

    private var currentAccentColor: Color {
        accentColor(for: selectedBackend)
    }

    private func accentColor(for backend: BackendId) -> Color {
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

    // MARK: - Network Actions

    @MainActor
    private func loadModels(for backend: BackendId) async {
        isLoadingModels = true
        modelLoadError = nil
        selectedModel = "" // Reset selection when backend changes

        do {
            let fetchedModels = try await apiClient.fetchModels(backend: backend)
            if !Task.isCancelled {
                self.models = fetchedModels
                self.isLoadingModels = false
            }
        } catch {
            if !Task.isCancelled {
                self.modelLoadError = error.localizedDescription
                self.isLoadingModels = false
            }
        }
    }

    @MainActor
    private func submitSession() async {
        guard canSubmit else { return }

        isSubmitting = true
        errorMessage = nil

        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let createRequest = SessionCreate(
            backend: selectedBackend,
            name: trimmedName,
            cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
            addDirs: [],
            model: selectedModel.isEmpty ? nil : selectedModel,
            effort: selectedEffort.isEmpty ? nil : selectedEffort
        )

        do {
            let newSession = try await apiClient.createSession(createRequest)
            isSubmitting = false
            dismiss()
            onCreated?(newSession)
        } catch {
            isSubmitting = false
            self.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Previews

struct NewSessionSheet_Previews: PreviewProvider {
    static var previews: some View {
        NewSessionSheet()
            .preferredColorScheme(.dark)
    }
}
