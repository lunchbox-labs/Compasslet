import ActivityKit
import Foundation
import CompassCore

struct CompassActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var bearing: Double?
    var status: Status
    var sampleTime: Date?
    var expiry: Date?
    var debugUpdateTime: Date? = nil
    var appearance: AppearanceValues? = nil
  }

  enum Status: String, Codable, Hashable, Sendable {
    case waiting, usable, slow, unreliable, unavailable
  }
}
