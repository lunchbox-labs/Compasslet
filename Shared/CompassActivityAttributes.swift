import ActivityKit
import Foundation

struct CompassActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var bearing: Double?
    var status: Status
    var sampleTime: Date?
    var expiry: Date?
  }

  enum Status: String, Codable, Hashable, Sendable {
    case waiting, usable, slow, unreliable, unavailable
  }
}
