import Testing
@testable import RewindCam

struct SmokeTests {
    @Test func appModuleLoads() {
        #expect(1 + 1 == 2)
    }
}
