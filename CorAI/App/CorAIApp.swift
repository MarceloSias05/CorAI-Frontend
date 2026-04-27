import SwiftUI

@main
struct CorAIApp: App {
    @State private var session = SessionManager.shared
    @State private var bleManager = BLEManager.shared
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            if session.isLoggedIn {
                MainTabView(repository: MockHomeRepository())
                    .preferredColorScheme(.light)
            } else {
                LoginView()
                    .preferredColorScheme(.light)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                bleManager.startScanning()
            }
        }
    }
}
