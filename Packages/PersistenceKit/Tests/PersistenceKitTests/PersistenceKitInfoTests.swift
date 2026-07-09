import Testing
@testable import PersistenceKit

@Test func packageCompilesAndLinksAgainstDomain() {
    #expect(PersistenceKitInfo.version == "0.1.0")
}
