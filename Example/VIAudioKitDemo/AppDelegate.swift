import UIKit
import VIAudioKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 确保调试日志在 Xcode Run 控制台可见（os_log Debug 常被系统过滤；echoToConsole 会同步 print）
        VILogger.level = .debug
        VILogger.echoToConsole = true

        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: AudioPlayerDemoController())
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
