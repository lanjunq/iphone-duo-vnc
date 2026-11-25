import SwiftUI
import UIKit
import DuoVNCKit
import DuoVNCSession

/// SwiftUI wrapper around the UIKit session screen.
struct SessionScreen: UIViewControllerRepresentable {
    let launch: SessionLaunch
    let onClose: () -> Void
    @EnvironmentObject var model: AppModel

    func makeUIViewController(context: Context) -> SessionViewController {
        let controller: SessionViewController = SessionViewController(endpoint: launch.endpoint, title: launch.title,
                                                                      settings: SessionSettings.current())
        let appModel: AppModel = model
        let close: () -> Void = onClose
        controller.onClose = {
            close()
        }
        controller.onPinHost = { [weak appModel] (host: SavedHost) in
            appModel?.pin(host)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: SessionViewController, context: Context) {
    }

    static func dismantleUIViewController(_ uiViewController: SessionViewController, coordinator: ()) {
        uiViewController.shutdown()
    }
}
