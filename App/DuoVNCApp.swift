import SwiftUI

/// App entry: the saved-host list; a session opens full screen on top of it.
@main
struct DuoVNCApp: App {
    @StateObject private var model: AppModel = AppModel()

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
