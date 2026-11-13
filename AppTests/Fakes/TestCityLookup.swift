import CoreLocation
@testable import Compass

/// A city lookup that holds each lookup for the test to answer, or, given a city, answers each
/// lookup with it at once.
@MainActor
final class TestCityLookup: PhoneCityLookup {
  /// The city every lookup answers with at once, or nil to hold each lookup.
  var city: String?
  var lookups = 0
  /// The completions of the held lookups, in the order they were asked.
  var completions: [@MainActor (String?) -> Void] = []
  var cancellations = 0

  init(city: String? = nil) { self.city = city }

  func lookup(_ location: CLLocation, completion: @escaping @MainActor (String?) -> Void) {
    lookups += 1
    if let city {
      completion(city)
    } else {
      completions.append(completion)
    }
  }

  func cancel() { cancellations += 1 }
}
