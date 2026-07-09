import Testing
@testable import LyricEngine

@Test func packageCompilesAndLinksAgainstDomain() {
    #expect(LyricEngineInfo.version == "0.1.0")
}
