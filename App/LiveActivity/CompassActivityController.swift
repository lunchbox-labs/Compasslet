import ActivityKit
import CompassCore
import Foundation
import Observation

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
  /// Whether any Compasslet Live Activity is showing, including one left from an earlier launch.
  var hasActivities: Bool { get }
}

/// Owns only the current compact presentation. Call start from an eligible drive start.
///
/// Starts, writes, rewrites and ends run in order on one queue, `operation`, each joining it when
/// it is called. A drive hands over only its latest presentation (`show`) and a clear that stays
/// pending until written (`invalidateReading`); one queued drain writes them once an activity
/// shows.
@MainActor
final class CompassActivityController: CompassActivityPresenting {
  enum Failure: Error { case unavailable, cancelled }
  var onDismiss: (() -> Void)?
  private let system: any CompassActivitySystem
  private let now: () -> Date
  private var handle: (any CompassActivityHandle)?
  private var starting = false
  /// Changes when the activity is dismissed or ended, so work queued for it stops.
  private var generation = UUID()
  /// Changes when the reading is cleared, so queued rewrites of older content stop.
  private var validity = UUID()
  private var lastUsableWrite: Date?
  /// When the activity's content and stale date were last written.
  private var lastWrite: Date?
  private var operation: Task<Void, Never>?
  private var appearance: AppearanceValues
  /// Rewrites the activity when the appearance preferences change.
  private var appearanceObservation: Task<Void, Never>?
  private var lastContent: CompassActivityAttributes.ContentState?
  /// The bearing the card shows, kept through stops until a changed reading or a clear.
  private var retainedBearing: Double?
  /// The newest presentation handed over and not yet written.
  private var pendingPresentation: TravelPresentation?
  /// Whether a clear of the retained reading waits to be written.
  private var pendingInvalidation = false
  /// Whether a drain of the pending clear and presentation is queued or running.
  private var drainQueued = false
  /// The shortest time between two changed readings written, from the update frequency. It is
  /// read at each write, so a change applies at once.
  private let refreshInterval: @MainActor () -> TimeInterval
  /// At an update frequency lower than the standard one, the newest changed reading that came too
  /// soon after the last one written. A drive's renewal writes it once the interval has passed,
  /// unless a newer write, a return to the direction shown or a clear replaces it first, so a turn
  /// just before a stop still reaches the card.
  private var heldReading: CompassActivityAttributes.ContentState?

  var canStartActivities: Bool { system.enabled }
  var hasActivities: Bool { system.hasActivities }

  /// How long a write keeps the activity current. A running drive renews it well before then, so
  /// only an activity whose app has stopped running goes stale and shows travel as unavailable,
  /// rather than an old direction.
  static let staleInterval: TimeInterval = 5 * 60
  /// How long an activity goes without a write before a running drive renews its stale date.
  static let renewalInterval: TimeInterval = 60

  init(
    system: any CompassActivitySystem = LocalCompassActivitySystem(),
    now: @escaping () -> Date = Date.init,
    appearanceStore: AppearanceStore = .shared,
    refreshInterval: @escaping @MainActor () -> TimeInterval = {
      CompassActivityController.changedReadingInterval
    }
  ) {
    self.system = system
    self.now = now
    self.refreshInterval = refreshInterval
    let initial = appearanceStore.preferences.effective(for: .activity)
    appearance = initial
    let changes = Observations { @MainActor in
      appearanceStore.preferences.effective(for: .activity)
    }
    appearanceObservation = Task { [weak self] in
      // The first value is the one read above, unless it has changed since.
      var last = initial
      for await value in changes where value != last {
        guard let self else { return }
        last = value
        self.updateAppearance(value)
      }
    }
  }

  isolated deinit { appearanceObservation?.cancel() }

  func start() async throws {
    guard handle == nil else { return }
    guard !starting, system.enabled else { throw Failure.unavailable }
    starting = true
    // A new activity has no retained reading to clear or replace.
    pendingInvalidation = false
    heldReading = nil
    let token = generation
    let previous = operation
    let requesting = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { throw Failure.cancelled }
      try await self.request(token)
    }
    operation = Task { _ = await requesting.result }
    try await requesting.value
  }

  /// Requests the activity at the head of the queue, then writes what was handed over meanwhile.
  private func request(_ token: UUID) async throws {
    do {
      // An end called while this waited in the queue cancels it before anything shows.
      guard generation == token else { throw Failure.cancelled }
      var initial = CompassActivityAttributes.ContentState(bearing: nil, status: .waiting)
      initial.appearance = appearance
      initial = stamped(initial)
      let created = try await system.request(initial)
      guard generation == token else {
        await created.end(.init(bearing: nil, status: .unavailable))
        throw Failure.cancelled
      }
      handle = created
      lastContent = initial
      try? CompassDiagnostics.shared?.observe(.activity, active: true)
      starting = false
      created.onDismiss = { [weak self] in self?.dismissed(token) }
      if initial.appearance != appearance { await rewrite(on: created) }
      await drain()
    } catch {
      if generation == token {
        starting = false
        pendingPresentation = nil
      }
      throw error
    }
  }

  /// The user or the system ended the activity, so nothing queued for it is written.
  private func dismissed(_ token: UUID) {
    guard generation == token else { return }
    generation = UUID()
    handle = nil
    lastContent = nil
    try? CompassDiagnostics.shared?.observe(.activity, active: false)
    lastUsableWrite = nil
    lastWrite = nil
    retainedBearing = nil
    heldReading = nil
    pendingPresentation = nil
    pendingInvalidation = false
    onDismiss?()
  }

  /// This is a sampled last-reading display, not a promise of live vehicle orientation.
  /// Unchanged readings get only the slow stale-date renewal; changed readings remain
  /// rate-limited, to this standard interval unless a lower update frequency is chosen.
  static let changedReadingInterval = LiveActivityUpdateFrequency.everySecond.interval

  func show(_ presentation: TravelPresentation) {
    pendingPresentation = presentation
    queueDrain()
  }

  func invalidateReading() {
    // A presentation handed over or held before the failure is older than it.
    pendingPresentation = nil
    heldReading = nil
    pendingInvalidation = true
    // Rewrites already queued would show the reading again before the clear.
    validity = UUID()
    queueDrain()
  }

  private func queueDrain() {
    guard !drainQueued else { return }
    drainQueued = true
    enqueue { [weak self] in
      guard let self else { return }
      await self.drain()
      self.drainQueued = false
    }
  }

  /// Writes the pending clear, then the latest presentation, then a held reading whose interval
  /// has passed, until nothing waits or the activity is gone. A clear that arrives during a write
  /// is written before anything handed over with it.
  private func drain() async {
    let token = generation
    while generation == token, let handle {
      if pendingInvalidation {
        pendingInvalidation = false
        await write(.init(sample: nil, status: .unavailable), retainingReading: false, on: handle)
      } else if let latest = pendingPresentation {
        pendingPresentation = nil
        await write(latest, retainingReading: true, on: handle)
      } else if let held = heldReading, refreshIntervalHasPassed(at: now()) {
        heldReading = nil
        if isRecentEnough(held, at: now()) { await commit(held, at: now(), on: handle) }
      } else {
        return
      }
    }
  }

  /// Whether a changed reading can be written at `date`: none has been yet, or the refresh
  /// interval has passed since the last one.
  private func refreshIntervalHasPassed(at date: Date) -> Bool {
    guard let lastUsableWrite else { return true }
    return Self.hasPassed(refreshInterval(), since: lastUsableWrite, at: date)
  }

  /// Whether `interval` has passed since `earlier`, or the clock is now before it, as after the
  /// clock is set back, so a limit never also waits out the time the clock went back.
  private static func hasPassed(_ interval: TimeInterval, since earlier: Date, at date: Date)
    -> Bool
  {
    let elapsed = date.timeIntervalSince(earlier)
    return elapsed >= interval || elapsed < 0
  }

  /// Whether a held reading is still worth writing: recorded no longer ago than the refresh
  /// interval and a reading's lifetime. A held reading is written up to an interval after it was
  /// recorded, past the lifetime a handed-over reading has, but one held longer, as when the
  /// renewal came late, or one dated after `date`, is passed over.
  private func isRecentEnough(
    _ held: CompassActivityAttributes.ContentState, at date: Date
  ) -> Bool {
    guard let sampleTime = held.sampleTime else { return false }
    // One recorded after `date`, as when the clock was set back since, would be dated ahead of it.
    let age = date.timeIntervalSince(sampleTime)
    return (0...(refreshInterval() + CompassSample.travelLifetime)).contains(age)
  }

  private func write(
    _ presentation: TravelPresentation, retainingReading: Bool, on handle: any CompassActivityHandle
  ) async {
    let date = now()
    let content = Self.content(presentation, now: date)
    // A bearing that aged out in the queue is passed over; any other sample that isn't current,
    // such as one dated ahead of the clock, clears the reading.
    let expiredTravelSample = presentation.sample?.hasExpired(at: date) ?? false
    if content.bearing == nil, retainingReading, retainedBearing != nil,
      (presentation.status != .usable || expiredTravelSample), presentation.status != .waiting
    {
      return
    }
    if let bearing = content.bearing {
      if let retainedBearing, let retained = CompassAngle(degrees: retainedBearing),
        let current = CompassAngle(degrees: bearing), Self.sameReading(retained, current)
      {
        // Back to the direction shown, so a reading held to replace it is older than this one.
        heldReading = nil
        return
      }
      let interval = refreshInterval()
      // At a slower rate, the first direction after a clear shows at once rather than waiting out
      // the interval; the standard rate keeps its limit, as before the setting existed.
      let limited = retainedBearing != nil || interval <= Self.changedReadingInterval
      if limited, let lastUsableWrite,
        !Self.hasPassed(interval, since: lastUsableWrite, at: date)
      {
        // At the standard rate the next reading follows about when the interval ends, so this one
        // is passed over; a slower rate holds it for the renewal to write.
        if interval > Self.changedReadingInterval { heldReading = content }
        return
      }
    }
    await commit(content, at: date, on: handle)
  }

  /// Writes content with the current appearance and a new stale date. A bearing becomes the one
  /// retained and starts a new refresh interval; content without one clears the retained reading.
  /// Either replaces a held reading.
  private func commit(
    _ content: CompassActivityAttributes.ContentState, at date: Date,
    on handle: any CompassActivityHandle
  ) async {
    var content = content
    if let bearing = content.bearing {
      lastUsableWrite = date
      retainedBearing = bearing
    } else {
      validity = UUID()
      retainedBearing = nil
    }
    heldReading = nil
    content.appearance = appearance
    content = stamped(content)
    lastContent = content
    await handle.update(content)
  }

  /// Changes only presentation, serialized with course updates and teardown.
  @discardableResult
  func updateAppearance(_ value: AppearanceValues) -> Task<Void, Never>? {
    appearance = value.requiringReadout()
    return rewriteLastContent()
  }

  /// Writes a held reading once its refresh interval has passed. Otherwise rewrites the current
  /// content with a new stale date once the last write is older than the renewal interval, so a
  /// long stop with nothing new to show doesn't make the activity stale.
  func renew() {
    guard handle != nil else { return }
    let date = now()
    if heldReading != nil, refreshIntervalHasPassed(at: date) {
      queueDrain()
      return
    }
    guard let lastWrite else { return }
    guard date.timeIntervalSince1970.isFinite,
      !(0..<Self.renewalInterval).contains(date.timeIntervalSince(lastWrite))
    else { return }
    // Set now, so the ticks before the queued write runs don't queue more.
    self.lastWrite = date
    rewriteLastContent()
  }

  func waitForPendingOperations() async { await operation?.value }

  /// Writes the last content again with the current appearance and a new stale date. The
  /// retained content keeps its original sample time, because a rewrite is not a new sample.
  @discardableResult
  private func rewriteLastContent() -> Task<Void, Never>? {
    guard let handle else { return nil }
    let token = generation
    let validityToken = validity
    return enqueue { [weak self] in
      guard let self, self.generation == token, self.validity == validityToken else { return }
      await self.rewrite(on: handle)
    }
  }

  private func rewrite(on handle: any CompassActivityHandle) async {
    guard var content = lastContent else { return }
    content.appearance = appearance
    content = stamped(content)
    lastContent = content
    await handle.update(content)
  }

  @discardableResult
  func end() -> Task<Void, Never> {
    generation = UUID()
    starting = false
    lastUsableWrite = nil
    lastWrite = nil
    retainedBearing = nil
    heldReading = nil
    pendingPresentation = nil
    pendingInvalidation = false
    let owned = handle
    handle = nil
    lastContent = nil
    try? CompassDiagnostics.shared?.observe(.activity, active: false)
    owned?.onDismiss = nil
    let system = system
    return enqueue {
      let finalState = CompassActivityAttributes.ContentState(bearing: nil, status: .unavailable)
      await owned?.end(finalState)
      await system.endSurvivors(finalState)
    }
  }

  /// Runs `work` after everything queued before it.
  @discardableResult
  private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let previous = operation
    let task = Task { @MainActor in
      await previous?.value
      await work()
    }
    operation = task
    return task
  }

  /// The content with a stale date measured from now, recorded as the latest write.
  private func stamped(_ content: CompassActivityAttributes.ContentState)
    -> CompassActivityAttributes.ContentState
  {
    var content = content
    let date = now()
    guard date.timeIntervalSince1970.isFinite else {
      content.expiry = nil
      return content
    }
    content.expiry = date.addingTimeInterval(Self.staleInterval)
    lastWrite = date
    return content
  }

  /// Whether two angles render the same rounded degrees and the same cardinal direction.
  static func sameReading(_ first: CompassAngle, _ second: CompassAngle) -> Bool {
    first.roundedDegrees == second.roundedDegrees
      && CompassPoint(angle: first) == CompassPoint(angle: second)
  }

  static func content(_ presentation: TravelPresentation, now: Date)
    -> CompassActivityAttributes.ContentState
  {
    let status = presentation.status
    guard status == .usable, let sample = presentation.sample, sample.isCurrent(at: now) else {
      return .init(bearing: nil, status: status == .usable ? .unavailable : status)
    }
    return .init(
      bearing: sample.angle.degrees, status: .usable, sampleTime: sample.timestamp,
      expiry: nil)
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
  var hasActivities: Bool {
    Activity<CompassActivityAttributes>.activities.contains {
      $0.activityState == .active || $0.activityState == .stale
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
    var content = state
    if CompassDiagnostics.shared?.isEnabled == true {
      content.debugUpdateTime = Date()
    }
    let diagnostics = CompassDiagnostics.shared
    let recordingSession = try? diagnostics?.recordingSession(.activity)
    if let recordingSession {
      _ = try? diagnostics?.record(
        .activity, kind: .updateRequested, matchingSession: recordingSession)
    }
    await activity.update(ActivityContent(state: content, staleDate: content.expiry))
    if let recordingSession {
      _ = try? diagnostics?.record(
        .activity, kind: .updateCompleted, matchingSession: recordingSession)
    }
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
