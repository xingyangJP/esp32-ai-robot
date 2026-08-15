import SwiftUI
import FirebaseCore

@main
struct RobotBrainApp: App {
    init() { FirebaseApp.configure() }   // reads GoogleService-Info.plist (bundled)
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
