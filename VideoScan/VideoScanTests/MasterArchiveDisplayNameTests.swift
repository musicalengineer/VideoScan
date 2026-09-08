import Testing
@testable import VideoScan

// The Archive sidebar's family header (Rick 2026-09-08) reads the name off
// the designated root folder so another family's archive shows their name.
struct MasterArchiveDisplayNameTests {
    @Test func underscoresBecomeSpaces() {
        #expect(MasterArchiveLayout.displayName(forRootPath: "/Volumes/FamilyArchive/Breen_Family_Archive")
                == "Breen Family Archive")
    }

    @Test func anotherFamilyGetsTheirOwnName() {
        #expect(MasterArchiveLayout.displayName(forRootPath: "/Volumes/X/Nguyen_Family_Archive")
                == "Nguyen Family Archive")
        #expect(MasterArchiveLayout.displayName(forRootPath: "/Volumes/X/The Carters") == "The Carters")
    }

    @Test func noDesignationIsTheGeneric() {
        #expect(MasterArchiveLayout.displayName(forRootPath: nil) == "Family Archive")
        #expect(MasterArchiveLayout.displayName(forRootPath: "") == "Family Archive")
        #expect(MasterArchiveLayout.displayName(forRootPath: "/Volumes/X/___") == "Family Archive")
    }
}
