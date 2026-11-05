import AppKit
import SwitchBladeCore

@main
struct SwitchBladeMain {
    @MainActor
    static func main() {
        // First thing: record which executable and signature this process
        // runs, before a racing bundle publication can change the path.
        LaunchIdentity.capture()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}
