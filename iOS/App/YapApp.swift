import Core
import SwiftUI

@main
struct YapApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                // The keyboard opens yap://dictate when there is no session:
                // only the app in front may open the microphone.
                .onOpenURL { url in
                    guard url.scheme == "yap" else { return }
                    Task { await session.start(thenRecord: url.host == "dictate") }
                }
        }
    }
}
