import Foundation
import Testing
@testable import VideoScanCore

@Suite("Compiled tree root override", .serialized)
struct FamilyGraphCompiledRootOverrideTests {
    @Test func environmentOverrideWinsAndUnsetFallsBackToApplicationSupport() {
        let key = FamilyGraphCompiledStore.compiledRootEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        setenv(key, "/private/tmp/some-scratch/compiled", 1)
        #expect(FamilyGraphCompiledStore.productionRoot.path == "/private/tmp/some-scratch/compiled")
        setenv(key, "", 1)
        #expect(FamilyGraphCompiledStore.productionRoot.path.hasSuffix("VideoScan/family-tree/compiled"))
        unsetenv(key)
        #expect(FamilyGraphCompiledStore.productionRoot.path.hasSuffix("VideoScan/family-tree/compiled"))
    }
}
