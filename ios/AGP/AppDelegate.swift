import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = Theme.background
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

enum Theme {
    /// #0b0c0e — the same ground the dashboard's own CSS paints, so the edges
    /// of the screen do not flash a different colour while a page loads.
    static let background = UIColor(red: 0x0b / 255, green: 0x0c / 255, blue: 0x0e / 255, alpha: 1)
    static let accent = UIColor(red: 1, green: 0, blue: 0.2, alpha: 1)
}
