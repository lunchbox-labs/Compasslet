import ActivityKit
import Foundation
import CompassCore

struct CompassActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var bearing: Double?
    var status: TravelStatus
    var sampleTime: Date?
    var expiry: Date?
    var debugUpdateTime: Date? = nil
    var appearance: AppearanceValues? = nil
  }
}
