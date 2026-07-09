import Testing
@testable import MelodyKit

@Test func packageCompilesAndLinksAgainstDomain() {
    #expect(MelodyKitInfo.version == "0.1.0")
}
