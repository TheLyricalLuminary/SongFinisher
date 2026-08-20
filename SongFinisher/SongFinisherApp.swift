import SwiftUI

@main
struct SongFinisherApp: App {
    private let services = AppServices.live()
    @State private var proStore = ProStore()

    var body: some Scene {
        WindowGroup {
            RootView(services: services, proStore: proStore)
        }
    }
}
