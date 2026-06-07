import Foundation

struct CoverageSample {
    let entryID: String
    let module: String?
    let name: String
    let percent: Double

    init(entry: TestEntry, percent: Double) {
        self.entryID = entry.id
        self.module = entry.module
        self.name = entry.name
        self.percent = percent
    }

    var isDebugFullSuite: Bool {
        module == "VideoScanTests (Debug)" && name == "Full XCTest suite (Debug)"
    }

    var isReleaseFullSuite: Bool {
        module == "VideoScanTests (Release)" && name == "Full XCTest suite (Release optimizer smoke)"
    }
}

enum CoverageAggregation {
    static func representativePercent(from samples: [CoverageSample]) -> Double? {
        representativeSample(from: samples)?.percent ?? averagePercent(from: samples)
    }

    static func representativeDescription(from samples: [CoverageSample]) -> String? {
        if let sample = representativeSample(from: samples) {
            return sample.name
        }
        guard !samples.isEmpty else { return nil }
        return "average of \(samples.count) coverage samples"
    }

    private static func representativeSample(from samples: [CoverageSample]) -> CoverageSample? {
        if let debug = samples.first(where: \.isDebugFullSuite) {
            return debug
        }
        if let release = samples.first(where: \.isReleaseFullSuite) {
            return release
        }
        return nil
    }

    private static func averagePercent(from samples: [CoverageSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return samples.map(\.percent).reduce(0, +) / Double(samples.count)
    }
}
