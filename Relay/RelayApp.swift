import SwiftUI

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) var appDelegate
    @State private var deepLinkedSessionName: String?

    private func openSession(from url: URL) {
        let sessionName: String?

        // Keep supporting the old link format so notifications already
        // delivered before the Universal Link rollout remain useful.
        if url.scheme?.lowercased() == "relay", url.host == "session" {
            sessionName = url.pathComponents.first { $0 != "/" }
        } else if url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "jdries.nl",
                  url.pathComponents.count == 4,
                  url.pathComponents[1] == "relay",
                  url.pathComponents[2] == "session" {
            sessionName = url.pathComponents[3]
        } else {
            sessionName = nil
        }

        guard let sessionName, !sessionName.isEmpty else { return }
        deepLinkedSessionName = sessionName
    }

    var body: some Scene {
        WindowGroup {
            SessionListView(deepLinkedSessionName: $deepLinkedSessionName)
                .task {
                    PushNotifications.requestAuthorizationAndRegister()
                }
                .onOpenURL { url in
                    openSession(from: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    openSession(from: url)
                }
        }
    }
}
