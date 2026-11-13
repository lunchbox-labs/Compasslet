import CompassCore
@testable import Compass

/// Records what the drive hands to its Live Activity. Its starts and ends finish at once unless a
/// test makes them fail or pause.
@MainActor
final class TestActivityPresenter: CompassActivityPresenting {
  enum Failure: Error { case unavailable }

  var onDismiss: (() -> Void)?
  var canStartActivities = true
  var hasActivities = false
  var starts = 0
  var renewals = 0
  func renew() { renewals += 1 }
  var invalidations = 0
  func invalidateReading() { invalidations += 1 }
  var ends = 0
  /// Every presentation handed over, in order.
  var updates: [TravelPresentation] = []
  var fails = false
  var pauseStart = false
  var startContinuation: CheckedContinuation<Void, Never>?
  var pauseEnd = false
  var endContinuation: CheckedContinuation<Void, Never>?
  func start() async throws {
    starts += 1
    if pauseStart {
      await withCheckedContinuation { startContinuation = $0 }
    }
    if fails { throw Failure.unavailable }
  }
  func show(_ presentation: TravelPresentation) { updates.append(presentation) }
  func end() -> Task<Void, Never> {
    ends += 1
    guard pauseEnd else { return Task {} }
    return Task { await withCheckedContinuation { self.endContinuation = $0 } }
  }
  func waitForPendingOperations() async {}
}
