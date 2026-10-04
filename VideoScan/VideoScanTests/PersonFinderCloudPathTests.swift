import Testing
import Foundation
@testable import VideoScan

// Rick 2026-10-04: "Search for Family" opened its picker on iCloud ▸
// ArchivedMedia and scanned it. Cloud-backed folders download on read, so
// startJob refuses them for every entry point.

@Suite("Person Finder — cloud folders refused")
@MainActor
struct PersonFinderCloudPathTests {

    @Test func recognisesICloudAndFileProviderFolders() {
        let home = NSHomeDirectory()
        for path in [home + "/Library/Mobile Documents/com~apple~CloudDocs/ArchivedMedia",
                     home + "/Library/Mobile Documents",
                     home + "/Library/CloudStorage/Dropbox/Videos",
                     home + "/Library/CloudStorage/GoogleDrive-x/My Drive"] {
            #expect(PersonFinderModel.isCloudBackedPath(path), "\(path)")
        }
    }

    @Test func localAndExternalFoldersAreFine() {
        for path in ["/Volumes/FamilyArchive/Videos", NSHomeDirectory() + "/Movies",
                     "/Volumes/Mobile Documents Backup", NSHomeDirectory() + "/Library/Mobile DocumentsX"] {
            #expect(!PersonFinderModel.isCloudBackedPath(path), "\(path)")
        }
    }

    @Test func startJobRefusesACloudFolderBeforeAnyWork() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/ArchivedMedia")
        model.startJob(job)
        guard case .failed(let reason) = job.status else {
            Issue.record("expected a refusal, got \(job.status)")
            return
        }
        #expect(reason.contains("iCloud"))
    }
}
