import ActivityKit
import CompassCore
import Foundation

@MainActor
protocol CompassActivityHandle: AnyObject {
  var onDismiss: (() -> Void)? { get set }
  func update(_ state: CompassActivityAttributes.ContentState) async
  func end(_ finalState: CompassActivityAttributes.ContentState) async
}

@MainActor
protocol CompassActivitySystem: AnyObject {
  var enabled: Bool { get }
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async
}

/// Owns only the current compact presentation. Call start from eligible CarPlay activation.
@MainActor
final class CompassActivityController: CompassActivityPresenting {
  enum Failure: Error { case unavailable, cancelled }
  var onDismiss: (() -> Void)?
  private let system: any CompassActivitySystem
  private let now: () -> Date
  private var handle: (any CompassActivityHandle)?
  private var starting = false
  private var generation = UUID()
  private var validity = UUID()
  private var lastUsableWrite: Date?
  private var operation: Task<Void, Never>?

  init(
    system: any CompassActivitySystem = LocalCompassActivitySystem(),
    now: @escaping () -> Date = Date.init
  ) {
    self.system = system
    self.now = now
  }

  func start() async throws {
    guard handle == nil else { return }
    guard !starting else { throw Failure.unavailable }
    guard system.enabled else { throw Failure.unavailable }
    starting = true
    let token = generation
    do {
      let created = try await system.request(.init(bearing: nil, status: .waiting))
      guard generation == token else {
        await created.end(.init(bearing: nil, status: .unavailable))
        throw Failure.cancelled
      }
      handle = created
      starting = false
      created.onDismiss = { [weak self] in
        guard let self, self.generation == token else { return }
        self.generation = UUID()
        self.handle = nil
        self.lastUsableWrite = nil
        self.onDismiss?()
      }
    } catch {
      if generation == token { starting = false }
      throw error
    }
  }

  func update(_ presentation: TravelPresentation) async {
    guard let handle else { return }
    let date = now()
    let state = Self.content(presentation, now: date)
    if state.bearing != nil, let lastUsableWrite, date.timeIntervalSince(lastUsableWrite) < 1 {
      return
    }
    if state.bearing != nil { lastUsableWrite = date } else { validity = UUID() }
    let validityToken = validity
    let token = generation
    let previous = operation
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, self.generation == token,
        state.bearing == nil || self.validity == validityToken
      else { return }
      // Revalidate after waiting so an expired sample never becomes a new bearing.
      await handle.update(Self.content(presentation, now: self.now()))
    }
    operation = task
    await task.value
  }

  func end() async {
    generation = UUID()
    starting = false
    lastUsableWrite = nil
    let owned = handle
    handle = nil
    owned?.onDismiss = nil
    let previous = operation
    let system = system
    let task = Task { @MainActor in
      await previous?.value
      let finalState = CompassActivityAttributes.ContentState(bearing: nil, status: .unavailable)
      await owned?.end(finalState)
      await system.endSurvivors(finalState)
    }
    operation = task
    await task.value
  }

  static func content(_ presentation: TravelPresentation, now: Date)
    -> CompassActivityAttributes.ContentState
  {
    let status: CompassActivityAttributes.Status
    switch presentation.status {
    case .waiting: status = .waiting
    case .usable: status = .usable
    case .slow: status = .slow
    case .unreliable: status = .unreliable
    case .unavailable: status = .unavailable
    }
    guard status == .usable, let sample = presentation.sample,
      sample.source == .vehicleCourse, sample.reference == .trueNorth,
      sample.angle.degrees.isFinite, (0..<360).contains(sample.angle.degrees),
      now.timeIntervalSince1970.isFinite, sample.timestamp.timeIntervalSince1970.isFinite,
      (0...5).contains(now.timeIntervalSince(sample.timestamp))
    else { return .init(bearing: nil, status: status == .usable ? .unavailable : status) }
    return .init(
      bearing: sample.angle.degrees, status: .usable, sampleTime: sample.timestamp,
      expiry: sample.timestamp.addingTimeInterval(5))
  }
}

@MainActor
private final class LocalCompassActivitySystem: CompassActivitySystem {
  var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  {
    let activity = try Activity.request(
      attributes: CompassActivityAttributes(),
      content: ActivityContent(state: state, staleDate: state.expiry), pushType: nil)
    return LocalCompassActivityHandle(activity)
  }
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async {
    for activity in Activity<CompassActivityAttributes>.activities {
      await activity.end(
        ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
    }
  }
}

@MainActor
private final class LocalCompassActivityHandle: CompassActivityHandle {
  var onDismiss: (() -> Void)?
  private let activityID: String
  private var observer: Task<Void, Never>?
  init(_ activity: Activity<CompassActivityAttributes>) {
    activityID = activity.id
    observer = Task { @MainActor [weak self] in
      for await state in activity.activityStateUpdates {
        guard !Task.isCancelled else { return }
        if state == .dismissed || state == .ended { self?.onDismiss?(); return }
      }
    }
  }
  deinit { observer?.cancel() }
  func update(_ state: CompassActivityAttributes.ContentState) async {
    await Self.update(activityID: activityID, state: state)
  }
  func end(_ finalState: CompassActivityAttributes.ContentState) async {
    observer?.cancel()
    onDismiss = nil
    await Self.end(activityID: activityID, finalState: finalState)
  }

  // Resolve the SDK handle locally so a retained main-actor value never crosses
  // into ActivityKit's concurrent update/end operations.
  nonisolated private static func update(
    activityID: String, state: CompassActivityAttributes.ContentState
  ) async {
    guard
      let activity = Activity<CompassActivityAttributes>.activities.first(where: {
        $0.id == activityID
      })
    else { return }
    await activity.update(ActivityContent(state: state, staleDate: state.expiry))
  }

  nonisolated private static func end(
    activityID: String, finalState: CompassActivityAttributes.ContentState
  ) async {
    guard
      let activity = Activity<CompassActivityAttributes>.activities.first(where: {
        $0.id == activityID
      })
    else { return }
    await activity.end(
      ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
  }
}
