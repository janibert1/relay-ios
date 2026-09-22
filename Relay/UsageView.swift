import SwiftUI

/// Real usage/quota view across ALL providers — Claude, Codex, Gemini
/// (subscription %), and OpenRouter (free-tier daily requests + paid
/// balance) — in one place. Built 2026-09-22: the backend endpoint
/// (`GET /api/usage`) and client method (`RelayAPIClient.getUsage`)
/// already existed, but nothing in the app ever actually called or
/// displayed it — Jan couldn't see usage anywhere despite the plumbing
/// being there. `check-usage.py` itself also didn't cover OpenRouter at
/// all until this same pass (its own real `/api/v1/key` endpoint has
/// free-tier + balance info, added there first).
struct UsageView: View {
    let apiClient: RelayAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var usage: UsageInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let backgroundColor = Color(red: 0.039, green: 0.039, blue: 0.039)
    private let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.102)
    private let cardBorder = Color(red: 0.165, green: 0.165, blue: 0.165)
    private let primaryTextColor = Color(red: 0.949, green: 0.949, blue: 0.949)
    private let dimTextColor = Color(red: 0.541, green: 0.541, blue: 0.541)
    private let dangerColor = Color(red: 1.0, green: 0.420, blue: 0.420)
    private let accentColor = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)

    init(apiClient: RelayAPIClient = .shared) {
        self.apiClient = apiClient
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(dangerColor)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground)
                            .cornerRadius(10)
                    }

                    if let usage {
                        Text(usage.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(primaryTextColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(cardBackground)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(cardBorder, lineWidth: 1)
                            )

                        Text("Fetched \(usage.fetchedAt)")
                            .font(.system(size: 11))
                            .foregroundColor(dimTextColor)
                    } else if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(backgroundColor.ignoresSafeArea())
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(dimTextColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundColor(accentColor)
                    .disabled(isLoading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            usage = try await apiClient.getUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
