import SwiftUI

/// Full-screen shell around the live https://relay.jdries.nl dashboard.
/// The dashboard itself is the real, complete app (session list, chat,
/// model switching, file uploads, usage panel) -- this shell only needs to
/// present it reliably and persist the session, same architecture decision
/// as the Commute app / Control Center.
struct RootView: View {
    private let dashboardURL = URL(string: "https://relay.jdries.nl")!

    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reloadTrigger = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WebView(url: dashboardURL, isLoading: $isLoading, loadFailed: $loadFailed, reloadTrigger: $reloadTrigger)
                .ignoresSafeArea(edges: .bottom)
                .opacity(loadFailed ? 0 : 1)

            if loadFailed {
                retryScreen
            }

            if isLoading && !loadFailed {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    private var retryScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Can't reach Relay")
                .font(.headline)
            Text("Check your connection, then try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                reloadTrigger += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
