// IdleExitPolicy.swift — VideoScanCore/Background
//
// "On demand, not resident forever" (design §3.2): the agent exits cleanly
// when the queue is empty and nothing has happened for 10 minutes; launchd
// (`KeepAlive: { SuccessfulExit: false }`) then leaves it down until the
// next XPC message. A pure function so the rule has one copy and a test.

import Foundation

public enum IdleExitPolicy {
    /// The design's default (§7 ruling 3, default kept tonight).
    public static let defaultIdleSeconds: Double = 600

    /// True when the service should `exit(0)`.
    /// - queueEmpty: no `queue/*.json` left (finished jobs are removed).
    /// - activeJobs: jobs running, pausing or paused (a paused job is work
    ///   waiting, so the service stays up to resume it).
    public static func shouldExit(idleSeconds: Double, queueEmpty: Bool, activeJobs: Int,
                                  threshold: Double = defaultIdleSeconds) -> Bool {
        queueEmpty && activeJobs == 0 && idleSeconds >= threshold
    }
}
