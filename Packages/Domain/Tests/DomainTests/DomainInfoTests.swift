import Testing
@testable import Domain

@Test func packageCompilesAndLinks() {
    #expect(DomainInfo.version == "0.1.0")
}
