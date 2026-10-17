import SwiftUI

@main
struct PathLightApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { phase in
                    if phase == .background || (phase != .active && model.running) {
                        model.stop(reason: "Paused while app is inactive")
                    }
                }
        }
    }
}
