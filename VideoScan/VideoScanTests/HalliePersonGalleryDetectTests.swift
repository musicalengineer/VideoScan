// HalliePersonGalleryDetectTests.swift
// Every lead form of "show all photos of X" becomes the photo shape
// (documents route to the same gallery answer), and the three pins stay:
// a bare "photos of donna" is a catalog search, and two people are never
// one portrait.

import Testing
@testable import VideoScan

@Suite("Person gallery — detection")
struct HalliePersonGalleryDetectTests {
    typealias Q = HallieLineageQuestion

    @Test(arguments: [
        "show all photos of ellen ronan",
        "show me all the photos of ellen ronan",
        "show every picture of ellen ronan",
        "show all pictures of ellen ronan",
        "all photos of ellen ronan",
        "show me pics of ellen ronan",
        "show the photos of ellen ronan",
        "show documents of ellen ronan",
        "show all documents of ellen ronan",
        "show me the papers of ellen ronan",
        "what documents do we have for ellen ronan",
        "what photos do you have of ellen ronan?",
        "show me a photo of ellen ronan",
        "are there any photos of ellen ronan",
    ])
    func galleryLeadFormsAreThePhotoShape(_ phrase: String) {
        #expect(Q.detect(phrase) == .personPhoto(person: "Ellen Ronan"), Comment(rawValue: phrase))
    }

    @Test func anApostropheNameIsCarriedAsTheCapitalizerSpellsIt() {
        // The capitalizer is shared with every other shape; the resolver
        // is case-insensitive, so "O'connor" still finds O'Connor.
        #expect(Q.detect("show all photos of mary o'connor")
                == .personPhoto(person: Q.capitalizedName("mary o'connor")))
    }

    @Test func thePinsHold() {
        #expect(Q.detect("photos of donna") == nil)
        #expect(Q.detect("find photos of me and donna") == nil)
        #expect(Q.detect("are there any photos of rick and donna") == nil)
        #expect(Q.detect("show all photos of rick and donna") == nil)
        // A year keeps it a media search, not a portrait.
        #expect(Q.detect("all photos of donna from 1992") == nil)
    }
}
