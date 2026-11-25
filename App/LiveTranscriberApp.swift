import SwiftUI

@main
struct LiveTranscriberApp: App {
    @StateObject private var model = SessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.handleAppBecameActive()
                    }
                }
        }
    }
}
