import SwiftUI

@main
struct SongFinisherApp: App {
    private let services = AppServices.live()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
        }
    }
}
