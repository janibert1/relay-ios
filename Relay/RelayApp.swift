import SwiftUI

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .task {
                    PushNotifications.requestAuthorizationAndRegister()
                }
        }
    }
}
