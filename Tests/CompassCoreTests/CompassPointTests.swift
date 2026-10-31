import CompassCore
import Foundation
import Testing

@Test func compassPointsCoverEverySectorWithCenteredBoundaries() throws {
  #expect(CompassPoint(degrees: 0) == .north)
  #expect(CompassPoint(degrees: 22.4) == .north)
  #expect(CompassPoint(degrees: 22.5) == .northeast)
  #expect(CompassPoint(degrees: 45) == .northeast)
  #expect(CompassPoint(degrees: 90) == .east)
  #expect(CompassPoint(degrees: 135) == .southeast)
  #expect(CompassPoint(degrees: 180) == .south)
  #expect(CompassPoint(degrees: 225) == .southwest)
  #expect(CompassPoint(degrees: 270) == .west)
  #expect(CompassPoint(degrees: 315) == .northwest)
  #expect(CompassPoint(degrees: 337.4) == .northwest)
  #expect(CompassPoint(degrees: 337.5) == .north)
  #expect(CompassPoint(degrees: 359.999) == .north)
  #expect(CompassPoint(degrees: 360) == .north)
  #expect(CompassPoint(degrees: -45) == .northwest)
  #expect(CompassPoint(degrees: .nan) == nil)
  #expect(CompassPoint(degrees: .infinity) == nil)
}

@Test func compassPointLabelsAndSpokenNamesIdentifyEachDirection() {
  // The abbreviation is what dials and readouts show; the name is what VoiceOver speaks.
  #expect(CompassPoint(degrees: 0)?.abbreviation == "N")
  #expect(CompassPoint(degrees: 0)?.name == "north")
  #expect(CompassPoint(degrees: 45)?.abbreviation == "NE")
  #expect(CompassPoint(degrees: 45)?.name == "northeast")
  #expect(CompassPoint(degrees: 225)?.abbreviation == "SW")
  #expect(CompassPoint(degrees: 225)?.name == "southwest")
  let abbreviations = CompassPoint.allCases.map(\.abbreviation)
  let names = CompassPoint.allCases.map(\.name)
  #expect(Set(abbreviations).count == abbreviations.count)
  #expect(Set(names).count == names.count)
}
