import Testing
@testable import SongFinisher

@Test @MainActor func appServicesFakesBuild() {
    _ = AppServices.fakes()
}
