import UIKit
import UserNotifications

/// Registers this device for real APNs push and reports the token to
/// push-relay (https://push.jdries.nl), the shared backend for all of Jan's
/// sideloaded apps. Replaces the old ntfy-based notification workaround --
/// no longer needed now that these apps are signed via Feather with full
/// AppTesters dev-account capability instead of running under LiveContainer.
///
/// Requires the app's own entitlements to declare
/// `aps-environment` = `production` (Feather/AppTesters-signed builds are
/// not sandbox builds), and requires push-relay to actually have a real
/// APNs Auth Key configured server-side before a sent notification will be
/// delivered -- see /home/jan/push-relay/README.md. Registration itself
/// (device token -> push-relay) works independently of that.
enum PushNotifications {
    /// Shared secret for push-relay's `Authorization: Bearer` auth. Same
    /// pragmatic "just a constant in the client" pattern as every other
    /// personal, never-published, ad-hoc-signed app here -- this is not a
    /// public API surface.
    private static let apiKey = "3caedbc3b3a54c42d9c78f32d670f1c0113d3e71f5dafe03d930afaf6d903ae2"
    private static let registerURL = URL(string: "https://push.jdries.nl/api/register")!

    static func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            guard granted, error == nil else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    static func reportDeviceToken(_ deviceToken: Data) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "bundle_id": bundleID,
            "token": tokenHex,
        ])

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("push-relay register failed: \(error)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("push-relay register failed: HTTP \(http.statusCode)")
            }
        }.resume()
    }
}

/// SwiftUI apps get no direct callback for
/// `didRegisterForRemoteNotificationsWithDeviceToken` -- it's an
/// AppDelegate-only API, so this thin adaptor exists purely to receive it
/// and hand off to `PushNotifications`.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.reportDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }
}
