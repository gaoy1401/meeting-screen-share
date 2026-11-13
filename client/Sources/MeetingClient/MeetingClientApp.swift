import SwiftUI

@main
struct MeetingClientApp: App {
    @StateObject private var model = MeetingModel()

    var body: some Scene {
        WindowGroup("Meeting UDP") {
            ContentView(model: model)
                .onAppear {
                    model.startIfRequested()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 860, height: 680)
    }
}
