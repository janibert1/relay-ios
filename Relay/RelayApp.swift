import SwiftUI

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) var appDelegate
    @State private var deepLinkedSessionName: String?

    var body: some Scene {
        WindowGroup {
            SessionListView(deepLinkedSessionName: $deepLinkedSessionName)
                .task {
                    PushNotifications.requestAuthorizationAndRegister()
                }
                .onOpenURL { url in
                    // ntfy completion notifications carry
                    // relay://session/<internal-session-name>. A malformed
                    // or unrelated link is simply ignored.
                    guard url.scheme?.lowercased() == "relay", url.host == "session" else {
                        return
                    }
                    let name = url.pathComponents.first { $0 != "/" } ?? ""
                    guard !name.isEmpty else { return }
                    deepLinkedSessionName = name
                }
        }
    }
}
