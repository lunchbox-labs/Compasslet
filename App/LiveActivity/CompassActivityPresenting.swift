import CompassCore

/// The adapter owns system activities, including cleanup of survivors from a prior process.
@MainActor
protocol CompassActivityPresenting: AnyObject {
  var onDismiss: (() -> Void)? { get set }
  func start() async throws
  func update(_ presentation: TravelPresentation) async
  /// Clears a retained reading after explicit acquisition failure, without ending the activity.
  func invalidateReading() async
  /// Ends all owned activities, including surviving activities before the first drive.
  func end() async
}

// Nonretaining presenters already represent interruption as unavailable.
extension CompassActivityPresenting {
  func invalidateReading() async { await update(.init(sample: nil, status: .unavailable)) }
}
