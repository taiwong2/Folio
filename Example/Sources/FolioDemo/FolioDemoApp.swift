import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct FolioDemoApp: App {
    @State private var state = DemoState()

    init() {
        // SPM executable targets launch with `.prohibited` activation policy on
        // macOS, which means no dock icon, no menu bar, and SwiftUI windows that
        // don't come to the front. Promote to a regular foreground app so the
        // window actually appears.
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("Folio Demo") {
            ContentView()
                .environment(state)
                .task {
                    // Kick off the EmbeddingGemma cold-start in the background
                    // as soon as the window appears. By the time the user picks
                    // a document and asks a question, the model is already
                    // downloaded, loaded, and the ANE is warmed up.
                    state.warmUpEmbeddingGemmaIfNeeded()
                }
        }
    }
}
