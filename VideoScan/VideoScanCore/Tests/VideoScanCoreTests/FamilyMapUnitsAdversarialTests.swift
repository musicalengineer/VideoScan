import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap units adversarial decoder")
struct FamilyMapUnitsAdversarialTests {
    @Test func booleanCoordinatesAreRefusedRatherThanTurnedIntoZeroAndOne() throws {
        let data = Data("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"key":"eng-x","name":"X","country":"ENG","kind":"county"},
           "geometry":{"type":"Polygon","coordinates":[
             [[false,false],[true,false],[true,true],[false,true],[false,false]]
           ]}}
        ]}
        """.utf8)
        #expect(throws: FamilyMapUnits.DecodeError.self) { try FamilyMapUnits(geoJSON: data) }
    }
}
