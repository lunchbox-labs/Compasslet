import CompassCore

/// The adapter owns system activities, including cleanup of survivors from a prior process.
/// Starts, writes and ends join one queue when they are called, so they take effect in the order
/// they were called.
@MainActor
protocol CompassActivityPresenting: AnyObject {
  var onDismiss: (() -> Void)? { get set }
  var canStartActivities: Bool { get }
  /// Whether any Live Activity is showing, including one left from an earlier launch.
  var hasActivities: Bool { get }
  /// Requests an activity once the work queued before it has finished, then shows the latest
  /// presentation handed over. Throws when the activity can't start or an end overtook it.
  func start() async throws
  /// Hands over the latest presentation. Only the newest one not yet written is kept.
  func show(_ presentation: TravelPresentation)
  /// Clears a retained reading after explicit acquisition failure, without ending the activity.
  /// The clear stays pending until it is written, and a presentation handed over before it is
  /// never written after it.
  func invalidateReading()
  /// Keeps a running drive's activity from going stale when it has had nothing new to show.
  func renew()
  /// Ends all owned activities, including surviving activities before the first drive, once the
  /// work queued before it has finished.
  @discardableResult func end() -> Task<Void, Never>
  /// Waits for the work queued so far.
  func waitForPendingOperations() async
}

// Nonretaining presenters already represent interruption as unavailable.
extension CompassActivityPresenting {
  func invalidateReading() { show(.init(sample: nil, status: .unavailable)) }
}
