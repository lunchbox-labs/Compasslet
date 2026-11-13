import CompassCore
import Foundation
import Observation

/// The drive's time and timers, so tests can set the time and run what has come due.
@MainActor
protocol DriveClock: AnyObject {
  var now: Date { get }
  /// Calls `fire` once `date` has come, unless the timer is cancelled first.
  func timer(at date: Date, _ fire: @escaping @MainActor () -> Void) -> DriveTimer
}

/// A call that a `DriveClock` makes later.
@MainActor
final class DriveTimer {
  private var stop: (@MainActor () -> Void)?

  init(cancel: @escaping @MainActor () -> Void) { stop = cancel }

  func cancel() {
    stop?()
    stop = nil
  }
}

/// The wall clock, with timers that sleep in a task until their time.
@MainActor
final class SystemDriveClock: DriveClock {
  var now: Date { Date() }

  func timer(at date: Date, _ fire: @escaping @MainActor () -> Void) -> DriveTimer {
    // Measured now, so the time the task takes to start doesn't lengthen the wait.
    let delay = date.timeIntervalSinceNow
    let task = Task { @MainActor in
      guard delay.isFinite else { return }
      if delay > 0 {
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
      guard !Task.isCancelled else { return }
      fire()
    }
    return DriveTimer { task.cancel() }
  }
}

@MainActor @Observable
final class DriveSessionController {
  /// The Live Activity as the phone and Shortcuts show it: `inactive` or `unavailable` with no
  /// drive, and otherwise how the drive's activity stands.
  enum CompactStatus { case inactive, starting, active, unavailable, dismissed }
  /// How a drive's Live Activity stands. Without CarPlay, only `starting` and `active` last.
  enum LiveActivityStatus {
    case starting, active, dismissed, unavailable

    /// Whether the activity is showing or about to, so it gets the drive's presentations.
    var isRunning: Bool { self == .starting || self == .active }
  }
  /// Whether a drive's car shows, and how its absence ends the drive.
  private enum CarPresence {
    case present
    /// The drive started away from the car, which hasn't shown since. The drive ends once
    /// `carPlayAbsenceLimit` passes without it.
    case awaited(since: Date)
    /// The car left during the drive. The drive ends once the auto-stop delay passes, unless
    /// auto-stop is never, or after `carPlayAbsenceLimit` while its Live Activity isn't running.
    case left(since: Date)
  }
  /// What location has reported during a drive's current start about the app not being in use.
  /// A start is the drive's beginning, or a later start of its Live Activity, which leaves
  /// location running as it was and so carries over only a report it hasn't recovered from.
  /// Unlike `DriveSession.notInUseSince`, it records reports while Compasslet is active on
  /// CarPlay too, and ends no drive.
  private enum NotInUseReport {
    /// No report during this start.
    case unreported
    /// Location reported at this time that the app isn't in use, with no newer reading since.
    case reported(at: Date)
    /// A reading newer than the report came, so location runs again.
    case recovered

    /// Whether location may not have started for this start, so a background start continues in
    /// the foreground. A report followed at once by a reading still counts, because the start
    /// can't yet show that location carries on.
    var needsForeground: Bool {
      if case .unreported = self { return false }
      return true
    }
  }
  /// No drive, or one drive. `liveActivityFailed` records that the last start ended because its
  /// Live Activity couldn't start, and without CarPlay nothing else would show the drive.
  private enum State {
    case idle(liveActivityFailed: Bool)
    case driving(DriveSession)
  }

  /// One drive, from the start of travel location to its end. Callbacks hold the drive they were
  /// made for, so one from an earlier drive fails `session === current`.
  @MainActor
  private final class DriveSession {
    let startedAt: Date
    var liveActivity = LiveActivityStatus.starting
    var filter = TravelCourseFilter()
    var lastReading: TravelReading?
    // Views don't observe these two, which only the intents read; a view needs a tracked one.
    /// Whether this drive has had a location reading, which shows location started.
    var hasReceivedReading = false
    /// What location reported during this start about the app not being in use.
    var notInUseReport = NotInUseReport.unreported
    /// Whether the car shows, and since when it hasn't while neither CarPlay nor car audio is
    /// connected.
    var car = CarPresence.present
    /// When location reported that the app isn't in use with no reading since.
    var notInUseSince: Date?
    /// Releases the background time held while waiting for a reading after that report.
    var releaseBackgroundTime: (@MainActor () -> Void)?
    var heartbeat: DriveTimer?
    /// The timer for the next limit, and when it fires.
    var deadline: DriveTimer?
    var deadlineDate: Date?

    init(startedAt: Date) { self.startedAt = startedAt }

    func cancelTimers() {
      heartbeat?.cancel()
      heartbeat = nil
      deadline?.cancel()
      deadline = nil
      deadlineDate = nil
    }
  }

  private(set) var presentation = TravelPresentation(sample: nil, status: .unavailable)
  private var state = State.idle(liveActivityFailed: false)
  private(set) var setupStatus: SetupStatus = .ready
  /// Whether Compasslet's CarPlay scene is connected, whether or not it's in front.
  private(set) var isCarPlayConnected = false
  /// Whether the iPhone's audio goes to CarPlay, which shows that the car is connected even
  /// when Compasslet isn't open on CarPlay, as when a CarPlay automation starts the drive.
  private(set) var isCarAudioConnected = false

  var isDriving: Bool { current != nil }

  var compactStatus: CompactStatus {
    switch state {
    case .idle(liveActivityFailed: true): return .unavailable
    case .idle: return .inactive
    case .driving(let session):
      switch session.liveActivity {
      case .starting: return .starting
      case .active: return .active
      case .dismissed: return .dismissed
      case .unavailable: return .unavailable
      }
    }
  }

  /// Whether a drive runs with its Live Activity starting or showing. A drive whose Live
  /// Activity was dismissed or couldn't start offers to start it again.
  var isLiveActivityRunning: Bool { current?.liveActivity.isRunning ?? false }

  /// Whether this drive has had a location reading, which shows location started.
  var hasReceivedReading: Bool { current?.hasReceivedReading ?? false }
  /// Whether location reported during the drive's current start that it can't run until the app
  /// is in use.
  var locationNeedsForeground: Bool { current?.notInUseReport.needsForeground ?? false }

  /// How long a drive started away from the car waits for CarPlay or car audio before it ends.
  /// It is also the standard auto-stop delay once the car leaves (`LiveActivityAutoStop`).
  static let carPlayAbsenceLimit: TimeInterval = 60
  /// How long a drive waits for a reading after location reports that the app isn't in use
  /// before it ends, since the report can arrive while readings still flow and readings can be
  /// sparse where GPS is weak, such as in a garage. It stays within the background time iOS gives.
  static let notInUseLimit: TimeInterval = 15
  /// How long a reading shows travel before it counts as old.
  static let readingLifetime = CompassSample.travelLifetime
  /// How long a drive runs at most.
  static let driveLimit: TimeInterval = 8 * 60 * 60
  /// How often a drive re-reads the car audio route and setup and renews its Live Activity, which
  /// keeps the activity's diagnostics clock running. Diagnostics treat a gap over 2 seconds as a
  /// new session.
  static let heartbeatInterval: TimeInterval = 1

  private let sensor: any TravelLocationSensor
  private let activity: any CompassActivityPresenting
  private let clock: any DriveClock
  private let readCarAudioRoute: @MainActor () -> Bool
  private let holdBackgroundTime: @MainActor () -> @MainActor () -> Void
  /// The auto-stop choice, read whenever a limit is checked or set, so a change applies to the
  /// drive in progress.
  private let autoStop: @MainActor () -> LiveActivityAutoStop
  @ObservationIgnored private var active = false
  @ObservationIgnored private var suppressed = false
  /// Whether the location prompt was asked for while permission is undecided. It clears once a
  /// decision arrives, because permission can become undecided again, as after Allow Once.
  @ObservationIgnored private var requestedPermission = false
  @ObservationIgnored private var preparation: Task<Void, Never>?
  /// The end of the last drive's Live Activity, and the background time it releases after.
  @ObservationIgnored private var ending: Task<Void, Never>?
  /// Wakes `needsForegroundStart` on each sensor event, CarPlay connection and drive end, so it
  /// checks again what it waits for.
  private let changes = ChangeSignal()

  init(
    sensor: any TravelLocationSensor, activity: any CompassActivityPresenting,
    clock: any DriveClock = SystemDriveClock(),
    carAudioRoute: @escaping @MainActor () -> Bool = { false },
    backgroundTime: @escaping @MainActor () -> @MainActor () -> Void = { {} },
    autoStop: @escaping @MainActor () -> LiveActivityAutoStop = {
      LiveActivityPreferences().autoStop
    }
  ) {
    self.sensor = sensor
    self.activity = activity
    self.clock = clock
    self.readCarAudioRoute = carAudioRoute
    self.holdBackgroundTime = backgroundTime
    self.autoStop = autoStop
    refreshSetupStatus()
    observeAuthorization()
  }

  isolated deinit {
    current?.cancelTimers()
    sensor.stop()
  }

  private var current: DriveSession? {
    guard case .driving(let session) = state else { return nil }
    return session
  }

  /// Called on ordinary phone launch to clear surviving activity state, never to acquire location.
  func prepare() async {
    if let preparation { await preparation.value; return }
    let operation = activity.end()
    preparation = operation
    await operation.value
  }

  /// Refresh on return from Settings; permission alone never starts travel acquisition.
  func phoneBecameActive(requestingPermission: Bool = true) async {
    await prepare()
    guard !Task.isCancelled else { return }
    refreshSetupStatus()
    if setupStatus != .ready { stopDrive() }
    // A failed phone start shouldn't keep asking for a setting the user has since changed.
    if case .idle(liveActivityFailed: true) = state, activity.canStartActivities {
      state = .idle(liveActivityFailed: false)
    }
    if requestingPermission { requestPhoneAuthorization(isForeground: true) }
  }

  /// Asks for location once while permission is undecided, so the inactive and active phases
  /// that the prompt itself causes don't ask again.
  func requestPhoneAuthorization(isForeground: Bool) {
    guard isForeground, !requestedPermission else { return }
    askForLocationPermission()
  }

  /// Asks for location because the user chose to, even if it was asked for before, as when the
  /// prompt closed without an answer because the app left the foreground.
  func askForLocationPermission() {
    refreshSetupStatus()
    guard setupStatus == .permissionRequired, sensor.authorization == .notDetermined else {
      return
    }
    requestedPermission = true
    sensor.requestAuthorization()
    refreshSetupStatus()
  }

  func carPlayConnected() {
    isCarPlayConnected = true
    current?.car = .present
    changes.signal()
  }

  /// Car audio keeps a drive going without Compasslet's CarPlay scene, and its loss starts the
  /// same auto-stop wait as a CarPlay disconnect.
  func carAudioChanged(connected: Bool) {
    isCarAudioConnected = connected
    guard let session = current else { return }
    if connected {
      session.car = .present
    } else if !isCarPlayConnected, case .present = session.car {
      session.car = .left(since: clock.now)
      armDeadline(for: session)
    }
  }

  func carPlayActivated() async {
    active = true
    carPlayConnected()
    // In use on CarPlay, location runs again.
    clearNotInUse()
    await prepare()
    refreshSetupStatus()
    guard active, !suppressed, !isDriving else { return }
    guard setupStatus == .ready else {
      return
    }
    await beginDrive()
  }

  /// The manual fallback for when the automatic CarPlay start doesn't produce a Live Activity.
  /// With no drive running, it starts one. Started without CarPlay, as from Shortcuts away
  /// from the car, the drive ends unless CarPlay connects within the absence limit. During a
  /// drive whose Live Activity was dismissed or couldn't start, it starts only the Live
  /// Activity again. Call it from the foreground app or a Live Activity intent, because
  /// ActivityKit only starts activities there.
  func startLiveActivity() async {
    await prepare()
    refreshSetupStatus()
    guard setupStatus == .ready else { return }
    guard let session = current else {
      // Without CarPlay the drive exists only for the Live Activity, so don't acquire
      // location when the system won't show one.
      guard isCarPlayConnected || activity.canStartActivities else {
        state = .idle(liveActivityFailed: true)
        return
      }
      await beginDrive()
      return
    }
    guard session.liveActivity == .dismissed || session.liveActivity == .unavailable else {
      return
    }
    // Location already runs for this drive, so a report it has since recovered from belongs to
    // an earlier start and mustn't send this one to the foreground. One it hasn't recovered from
    // still does, since location may be stopped.
    if case .recovered = session.notInUseReport { session.notInUseReport = .unreported }
    setLiveActivity(.starting, for: session)
    await startActivity(for: session)
  }

  private func beginDrive() async {
    let session = DriveSession(startedAt: clock.now)
    sensor.receive = { [weak self, weak session] event in
      guard let self, let session else { return }
      self.receive(event, for: session)
    }
    do { try sensor.start() } catch {
      sensor.stop()
      // No drive follows, so a permission change must still refresh the status set here.
      observeAuthorization()
      setupStatus = .unavailable
      state = .idle(liveActivityFailed: false)
      return
    }
    // A notification can be missed while the app is suspended, so read the route itself.
    isCarAudioConnected = readCarAudioRoute()
    if !isCarPlayConnected, !isCarAudioConnected {
      session.car = .awaited(since: session.startedAt)
    }
    presentation = TravelPresentation(sample: nil, status: .waiting)
    state = .driving(session)
    scheduleHeartbeat(for: session)
    armDeadline(for: session)
    await startActivity(for: session)
  }

  private func startActivity(for session: DriveSession) async {
    activity.onDismiss = { [weak self, weak session] in
      guard let self, let session, session === self.current else { return }
      // ActivityKit ends activities on its own, so during a CarPlay drive losing the
      // compact card only ends its updates until CarPlay disconnects or the user ends it.
      // Without CarPlay nothing else shows the drive, so it ends too.
      guard self.isCarPlayConnected else {
        self.stopDrive()
        return
      }
      self.setLiveActivity(.dismissed, for: session)
    }
    // The activity shows the drive's latest presentation once it starts.
    activity.show(presentation)
    do {
      try await activity.start()
      guard session === current, session.liveActivity == .starting else { return }
      setLiveActivity(.active, for: session)
    } catch {
      guard session === current else { return }
      guard isCarPlayConnected else {
        stopDrive(liveActivityFailed: true)
        return
      }
      setLiveActivity(.unavailable, for: session)
    }
  }

  func carPlayResignedActive() {
    active = false
    suppressed = false
  }

  /// A brief disconnect keeps the drive; auto-stop ends it once CarPlay stays away for the chosen
  /// delay, unless auto-stop is never. Car audio that stays connected keeps the drive too.
  func carPlayDisconnected() {
    active = false
    suppressed = false
    isCarPlayConnected = false
    guard let session = current, !isCarAudioConnected, case .present = session.car else {
      return
    }
    session.car = .left(since: clock.now)
    armDeadline(for: session)
  }

  func endDrive() async {
    // Only an active scene must be left before the next explicit reopen.
    suppressed = active
    await stopDrive()?.value
  }

  /// Ends the drive, and any Live Activity left from an earlier launch, from the app or Shortcuts.
  func endLiveActivity() async {
    await prepare()
    await endDrive()
  }

  func waitForPendingOperations() async {
    await ending?.value
    await activity.waitForPendingOperations()
  }

  /// Whether a Live Activity is showing, including one left from an earlier launch.
  var hasLiveActivity: Bool { activity.hasActivities }

  /// After a start from the background, waits for location and reports whether it couldn't
  /// start without the app in use, judged by what location reported during this start. A drive
  /// that ended meanwhile, or one with Compasslet's CarPlay scene, never needs a foreground start.
  func needsForegroundStart(waitingUpTo timeout: Duration) async -> Bool {
    guard let session = current, !isCarPlayConnected else { return false }
    let clock = ContinuousClock()
    let start = clock.now
    // A reading can arrive before the session reports that the app isn't in use.
    func settled() -> Bool {
      session.notInUseReport.needsForeground
        || (session.hasReceivedReading && clock.now - start >= .seconds(1))
    }
    while session === current, !isCarPlayConnected, !settled(), clock.now - start < timeout {
      guard !Task.isCancelled else { return false }
      // Wakes on the next change, or when the second after a reading or the timeout ends.
      let wait = session.hasReceivedReading ? min(timeout, .seconds(1)) : timeout
      await changes.wait(until: start + wait)
      guard !Task.isCancelled else { return false }
    }
    guard session === current, !isCarPlayConnected else { return false }
    return session.notInUseReport.needsForeground || !session.hasReceivedReading
  }

  private func observeAuthorization() {
    sensor.receive = { [weak self] event in
      if case .authorizationChanged = event { self?.refreshSetupStatus() }
    }
  }

  private func refreshSetupStatus() {
    if sensor.authorization != .notDetermined { requestedPermission = false }
    let status = SetupStatus(sensor: sensor)
    // It refreshes on every reading and beat, so set it only when it changes, or each one would
    // redraw the views that show it.
    if setupStatus != status { setupStatus = status }
  }

  private func receive(_ event: TravelSensorEvent, for session: DriveSession) {
    guard session === current else { return }
    refreshSetupStatus()
    guard setupStatus == .ready else {
      stopDrive()
      return
    }
    switch event {
    case .authorizationChanged: break
    case .authorizationLost:
      setupStatus = .denied
      stopDrive()
    case .notInUse:
      session.notInUseReport = .reported(at: clock.now)
      // Compasslet in use on CarPlay keeps location running.
      if !active, session.notInUseSince == nil {
        session.notInUseSince = clock.now
        // A drive that lost location in the background could otherwise be suspended before
        // it ends.
        session.releaseBackgroundTime = holdBackgroundTime()
        armDeadline(for: session)
      }
    case .interrupted:
      session.lastReading = nil
      if session.liveActivity.isRunning { activity.invalidateReading() }
      publish(session.filter.update(nil, now: clock.now), for: session)
    case .reading(let reading):
      // A reading taken before the report doesn't show that location still runs.
      if let since = session.notInUseSince, reading.timestamp > since { clearNotInUse() }
      if case .reported(let at) = session.notInUseReport, reading.timestamp > at {
        session.notInUseReport = .recovered
      }
      session.lastReading = reading
      session.hasReceivedReading = true
      publish(session.filter.update(reading, now: clock.now), for: session)
      armDeadline(for: session)
    }
    changes.signal()
  }

  /// Shows a presentation, and hands it to the Live Activity while that is starting or showing.
  private func publish(_ value: TravelPresentation, for session: DriveSession) {
    presentation = value
    if session.liveActivity.isRunning { activity.show(value) }
  }

  private func setLiveActivity(_ status: LiveActivityStatus, for session: DriveSession) {
    session.liveActivity = status
    // The session isn't observable, so setting the state again tells views the status changed.
    if session === current { state = .driving(session) }
  }

  /// Sets the next beat an interval after now, so each gap is at least the interval and a late
  /// beat brings no burst of catch-up beats. Diagnostics skip calls under 1 s apart.
  private func scheduleHeartbeat(for session: DriveSession) {
    let date = clock.now.addingTimeInterval(Self.heartbeatInterval)
    session.heartbeat = clock.timer(at: date) { [weak self, weak session] in
      guard let self, let session else { return }
      self.beat(session)
    }
  }

  /// The drive's regular work. Once this stops running, as when the app's process ends, the
  /// Live Activity goes stale on its own.
  private func beat(_ session: DriveSession) {
    guard session === current else { return }
    let carAudio = readCarAudioRoute()
    if carAudio != isCarAudioConnected { carAudioChanged(connected: carAudio) }
    refreshSetupStatus()
    let elapsed = clock.now.timeIntervalSince(session.startedAt)
    guard setupStatus == .ready, (0..<Self.driveLimit).contains(elapsed) else {
      stopDrive()
      return
    }
    if endsAtLimit(session) { return }
    // Keeps the activity current through a stop with nothing new to show. A starting activity may
    // already show, so it is renewed too; the activity's controller does nothing without one.
    if session.liveActivity.isRunning { activity.renew() }
    expireReading(of: session)
    armDeadline(for: session)
    scheduleHeartbeat(for: session)
  }

  /// Ends the drive when the car has been away too long, or when location stopped because the
  /// app isn't in use and no newer reading came, and reports whether it did.
  private func endsAtLimit(_ session: DriveSession) -> Bool {
    if let absence = carAbsence(of: session), hasPassed(absence.limit, since: absence.since) {
      stopDrive()
      return true
    }
    // Location stopped because the app isn't in use, so the drive can't show travel.
    if !active, let since = session.notInUseSince, hasPassed(Self.notInUseLimit, since: since) {
      stopDrive()
      return true
    }
    return false
  }

  /// How long the car can stay away, and since when it has: the start window for a drive started
  /// away from it, or the auto-stop delay once it has left. Nil while the car shows, or once it
  /// has left when auto-stop is never. Auto-stop keeps only a drive whose Live Activity is
  /// starting or showing; one whose Live Activity was dismissed or couldn't start shows nothing
  /// once the car has gone, so it ends after the standard minute whatever auto-stop is set to.
  private func carAbsence(of session: DriveSession) -> (since: Date, limit: TimeInterval)? {
    switch session.car {
    case .present:
      return nil
    case .awaited(let since):
      return (since: since, limit: Self.carPlayAbsenceLimit)
    case .left(let since):
      guard session.liveActivity.isRunning else {
        return (since: since, limit: Self.carPlayAbsenceLimit)
      }
      return autoStop().delay.map { (since: since, limit: $0) }
    }
  }

  private func expireReading(of session: DriveSession) {
    guard let reading = session.lastReading,
      hasPassed(Self.readingLifetime, since: reading.timestamp)
    else { return }
    publish(session.filter.update(nil, now: clock.now), for: session)
    session.lastReading = nil
  }

  /// Sets a timer for the next limit, so each one ends on time rather than at the next beat.
  private func armDeadline(for session: DriveSession) {
    var dates: [Date] = []
    if let absence = carAbsence(of: session) {
      dates.append(passing(absence.limit, since: absence.since))
    }
    if !active, let since = session.notInUseSince {
      dates.append(passing(Self.notInUseLimit, since: since))
    }
    if let reading = session.lastReading {
      dates.append(passing(Self.readingLifetime, since: reading.timestamp))
    }
    // A timer already set for an earlier time sets the next one when it fires.
    guard let next = dates.min(), next < session.deadlineDate ?? .distantFuture else { return }
    session.deadline?.cancel()
    session.deadlineDate = next
    session.deadline = clock.timer(at: next) { [weak self, weak session] in
      guard let self, let session else { return }
      session.deadline = nil
      session.deadlineDate = nil
      self.deadlineCame(for: session)
    }
  }

  private func deadlineCame(for session: DriveSession) {
    guard session === current, !endsAtLimit(session) else { return }
    expireReading(of: session)
    armDeadline(for: session)
  }

  /// Whether more than `limit` seconds have passed since `date`, or the clock is before it.
  private func hasPassed(_ limit: TimeInterval, since date: Date) -> Bool {
    !(0...limit).contains(clock.now.timeIntervalSince(date))
  }

  /// When `hasPassed(_:since:)` becomes true: now, if the clock is before `date`, and otherwise
  /// the first moment after the limit, because the limit itself still counts as within it.
  private func passing(_ limit: TimeInterval, since date: Date) -> Date {
    let now = clock.now
    guard now >= date else { return now }
    let end = date.addingTimeInterval(limit).timeIntervalSinceReferenceDate
    return Date(timeIntervalSinceReferenceDate: end.nextUp)
  }

  /// Ends the drive and its Live Activity, recording whether it ended because the Live Activity
  /// couldn't start.
  @discardableResult
  private func stopDrive(liveActivityFailed: Bool = false) -> Task<Void, Never>? {
    guard let session = current else { return nil }
    state = .idle(liveActivityFailed: liveActivityFailed)
    session.cancelTimers()
    // The background time keeps the app running until the Live Activity has ended.
    let releaseBackgroundTime = session.releaseBackgroundTime
    session.releaseBackgroundTime = nil
    sensor.stop()
    observeAuthorization()
    presentation = TravelPresentation(sample: nil, status: .unavailable)
    activity.onDismiss = nil
    let ended = activity.end()
    let task = Task { @MainActor in
      await ended.value
      releaseBackgroundTime?()
    }
    ending = task
    changes.signal()
    return task
  }

  private func clearNotInUse() {
    guard let session = current else { return }
    session.notInUseSince = nil
    session.releaseBackgroundTime?()
    session.releaseBackgroundTime = nil
  }
}
