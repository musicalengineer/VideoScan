import Testing

@Suite struct CICanaryTests {

    // Deliberate failure — proves the test runner can detect and report
    // a real failure. CI verifies this test appears as "failed" in the
    // output. If it shows "passed" or is absent, tests are ghost-passing.
    @Test func mustFail() {
        #expect(1 == 2)
    }

    // Deliberate pass — proves the runner executes both outcomes.
    @Test func mustPass() {
        #expect(1 == 1)
    }
}
