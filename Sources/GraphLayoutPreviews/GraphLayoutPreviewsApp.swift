import GraphLayoutGallery
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

@main
struct GraphLayoutPreviewsApp: App {
    #if canImport(AppKit)

    init() {
        // A SwiftPM executable has no Info.plist, so promote it to a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    #endif

    var body: some Scene {
        WindowGroup("SwiftGraph Layouts") {
            GalleryView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
