import Foundation
import Observation
import Synchronization

/// Local timing evidence only. An event never proves that CarPlay painted a frame.
///
/// Only the app's own process writes it: from the main actor on drive heartbeats and CarPlay
/// passes and ticks, and from Live Activity updates off it. Every call runs under one lock and
/// returns once written, so a session's start, pause and total land in the order the calls were
/// made.
/// The store is two files in the app's Application Support: `settings.json` holds the switch,
/// each surface's clock and the next sequence number, and `events.jsonl` holds one event per
/// line, appended as it is recorded.
final class CompassDiagnostics: Observable, Sendable {
  enum Surface: String, Codable, CaseIterable { case activity, fullscreen }
  enum Kind: String, Codable {
    case started, paused, updateRequested, updateCompleted
    case templateUpdated
  }
  struct Event: Codable, Equatable {
    let sequence: Int64
    let surface: Surface
    let kind: Kind
    let timestamp: Double
    let elapsedSinceFirstRetainedEvent: Double
    let activeSeconds: Double
    let session: String
  }
  struct IntervalSummary: Codable {
    let kind: Kind
    let count: Int
    let meanIntervalSeconds: Double?
  }
  struct SurfaceSummary: Codable {
    let surface: Surface
    let activeSeconds: Double
    let intervals: [IntervalSummary]
  }
  struct Snapshot: Codable {
    let explanation: String
    let surfaces: [SurfaceSummary]
    let events: [Event]
  }
  enum Failure: Error, LocalizedError {
    case unavailable, database
    var errorDescription: String? {
      switch self {
      case .unavailable: "Diagnostics are unavailable. The app’s storage couldn’t be opened."
      case .database: "The local diagnostics store could not be read or written."
      }
    }
  }

  /// The writes the store makes, so a test can make one fail part-way.
  struct Storage: Sendable {
    /// Replaces a whole file atomically.
    var replace: @Sendable (Data, URL) throws -> Void = { data, url in
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Writes bytes at a file handle's current offset.
    var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
  }

  static let shared: CompassDiagnostics? = {
    #if os(iOS)
      removeLegacyStore(
        in: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: legacyGroup))
      do {
        var directory = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory.appendPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.path)
        return try CompassDiagnostics(directory: directory)
      } catch { return nil }
    #else
      return nil
    #endif
  }()

  /// The App Group that held the SQLite store before it moved to Application Support.
  private static let legacyGroup = "group.dev.lunchbox-labs.carplay-compass"

  /// Deletes the old store's `Diagnostics` folder from the App Group container, if it's there,
  /// because its events can no longer be cleared from Settings.
  static func removeLegacyStore(in container: URL?) {
    guard let folder = container?.appendingPathComponent("Diagnostics", isDirectory: true),
      FileManager.default.fileExists(atPath: folder.path)
    else { return }
    try? FileManager.default.removeItem(at: folder)
  }

  /// One surface's active-time clock, as of its last observation.
  private struct Clock: Codable {
    var total: Double
    var wall: Double
    var uptime: Double
    /// The process that wrote it, so a relaunch starts a new session.
    var owner: String
    var session: String
    var active: Bool
  }
  /// One stored event. A line naming a surface or kind this version doesn't record doesn't
  /// decode, so it's dropped when the store opens.
  private struct Record: Codable {
    let sequence: Int64
    let surface: Surface
    let kind: Kind
    let wall: Double
    let uptime: Double
    let elapsed: Double
    let session: String
  }
  private struct Settings: Codable {
    var enabled = false
    var clocks: [String: Clock] = [:]
    var nextSequence: Int64 = 1
  }
  private struct State {
    var settings: Settings
    /// The retained events, oldest first.
    var events: [Record]
    /// How many lines the events file holds, retained or not.
    var lines: Int
    /// The line count at which to try compacting again after a rewrite failed.
    var retryCompactionAt = 0
    var lastObservation: [Surface: (uptime: Double, active: Bool)] = [:]
  }

  /// How many active seconds of events each surface keeps.
  private static let retainedSeconds: Double = 1800

  let directory: URL
  private let settingsURL: URL
  private let eventsURL: URL
  /// How many events each surface keeps at most.
  private let retainedEvents: Int
  private let storage: Storage
  private let process = UUID().uuidString
  private let registrar = ObservationRegistrar()
  private let state: Mutex<State>

  /// Opens the store in `directory`, which must exist. Files that can't be read leave it
  /// unopened. A settings file that reads but doesn't decode can't say whether Debug Mode is on,
  /// so both files are deleted and the store starts off.
  init(directory: URL, retainedEvents: Int = 50_000, storage: Storage = Storage()) throws {
    let manager = FileManager.default
    let settingsURL = directory.appendingPathComponent("settings.json")
    let eventsURL = directory.appendingPathComponent("events.jsonl")
    var settings = Settings()
    var data = Data()
    do {
      if manager.fileExists(atPath: settingsURL.path) {
        let raw = try Data(contentsOf: settingsURL)
        if let decoded = try? JSONDecoder().decode(Settings.self, from: raw) {
          settings = decoded
        } else {
          try manager.removeItem(at: settingsURL)
          if manager.fileExists(atPath: eventsURL.path) { try manager.removeItem(at: eventsURL) }
        }
      }
      if manager.fileExists(atPath: eventsURL.path) { data = try Data(contentsOf: eventsURL) }
    } catch { throw Failure.database }
    // A line that doesn't decode, such as one cut short when the app stopped mid-write, is
    // dropped rather than making the whole log unreadable.
    let stored = data.split(separator: 0x0A)
    let decoder = JSONDecoder()
    var events = stored.compactMap { try? decoder.decode(Record.self, from: Data($0)) }
    events.sort { $0.sequence < $1.sequence }
    settings.nextSequence = max(settings.nextSequence, (events.last?.sequence ?? 0) + 1)
    for surface in Surface.allCases {
      guard let total = settings.clocks[surface.rawValue]?.total else { continue }
      CompassDiagnostics.prune(&events, surface: surface, total: total, limit: retainedEvents)
    }
    var state = State(settings: settings, events: events, lines: stored.count)
    // Rewriting drops what was left out, and ends the file on a whole line for the next append.
    if events.count != stored.count || !(data.isEmpty || data.last == 0x0A) {
      do { try storage.replace(CompassDiagnostics.lines(events), eventsURL) } catch {
        throw Failure.database
      }
      state.lines = events.count
    }
    self.directory = directory
    self.settingsURL = settingsURL
    self.eventsURL = eventsURL
    self.retainedEvents = retainedEvents
    self.storage = storage
    self.state = Mutex(state)
  }

  /// Whether Debug Mode is on. A view that reads it updates when it changes.
  var isEnabled: Bool {
    registrar.access(self, keyPath: \.isEnabled)
    return state.withLock { $0.settings.enabled }
  }

  func setEnabled(_ value: Bool) throws {
    try registrar.withMutation(of: self, keyPath: \.isEnabled) {
      try state.withLock { state in
        state.lastObservation.removeAll()
        var settings = state.settings
        settings.enabled = value
        if value {
          // Resume on the next lifecycle tick, never from an old wall-clock timestamp.
          for surface in settings.clocks.keys { settings.clocks[surface]?.active = false }
        } else {
          // Erase the events before saving the switch, so a failed erase leaves Debug Mode on.
          try erase(&state)
          settings.clocks.removeAll()
        }
        try commit(settings, to: &state)
      }
    }
  }

  /// Called by existing lifecycle ticks, and by CarPlay's one-second tick only while Debug Mode is
  /// on, a drive runs and Compasslet is in front on CarPlay. Gaps are not assumed active.
  func observe(
    _ surface: Surface, active: Bool,
    wall: Double = Date().timeIntervalSince1970,
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) throws {
    guard wall.isFinite, uptime.isFinite else { return }
    try state.withLock { state in
      if let previous = state.lastObservation[surface], previous.active == active,
        (0..<1).contains(uptime - previous.uptime)
      {
        return
      }
      state.lastObservation[surface] = (uptime, active)
      guard state.settings.enabled else { return }
      let last = state.settings.clocks[surface.rawValue]
      var total = last?.total ?? 0
      let wasActive = last?.active ?? false
      guard active || wasActive else { return }
      let delta = uptime - (last?.uptime ?? uptime)
      let continuing = wasActive && last?.owner == process && (0...2).contains(delta)
      if continuing { total += delta }
      let session = continuing ? (last?.session ?? UUID().uuidString) : UUID().uuidString
      var settings = state.settings
      settings.clocks[surface.rawValue] = Clock(
        total: total, wall: wall, uptime: uptime, owner: process, session: session, active: active)
      var added: [Record] = []
      let kind: Kind? = active && !continuing ? .started : (wasActive && !active ? .paused : nil)
      if let kind {
        let event = Record(
          sequence: settings.nextSequence, surface: surface, kind: kind, wall: wall, uptime: uptime,
          elapsed: total, session: session)
        added.append(event)
        settings.nextSequence += 1
      }
      try commit(settings, appending: added, pruning: surface, to: &state)
    }
  }

  /// Capture before asynchronous work so its completion cannot enter a later recording session.
  func recordingSession(_ surface: Surface) throws -> String? {
    state.withLock { state in
      guard state.settings.enabled, let clock = state.settings.clocks[surface.rawValue],
        clock.active
      else { return nil }
      return clock.session
    }
  }

  /// Append only while the app has recently observed an eligible feed.
  @discardableResult
  func record(
    _ surface: Surface, kind: Kind, matchingSession: String? = nil,
    wall: Double = Date().timeIntervalSince1970,
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) throws -> Bool {
    guard wall.isFinite, uptime.isFinite else { return false }
    return try state.withLock { state in
      guard state.settings.enabled, let clock = state.settings.clocks[surface.rawValue],
        clock.active, matchingSession == nil || matchingSession == clock.session,
        (0...2).contains(uptime - clock.uptime), (0...3).contains(wall - clock.wall)
      else { return false }
      var settings = state.settings
      let event = Record(
        sequence: settings.nextSequence, surface: surface, kind: kind, wall: wall, uptime: uptime,
        elapsed: clock.total, session: clock.session)
      settings.nextSequence += 1
      try commit(settings, appending: [event], pruning: surface, savingSettings: false, to: &state)
      return true
    }
  }

  func clear() throws {
    try state.withLock { state in
      state.lastObservation.removeAll()
      try erase(&state)
      var settings = state.settings
      settings.clocks.removeAll()
      try commit(settings, to: &state)
    }
  }

  func snapshot() throws -> Snapshot {
    let (records, clocks) = state.withLock { ($0.events, $0.settings.clocks) }
    var origins: [String: Double] = [:]
    for record in records {
      origins[record.session] = min(origins[record.session] ?? record.uptime, record.uptime)
    }
    let events = records.map { record -> Event in
      let origin = origins[record.session, default: record.uptime]
      return Event(
        sequence: record.sequence, surface: record.surface, kind: record.kind,
        timestamp: record.wall, elapsedSinceFirstRetainedEvent: record.uptime - origin,
        activeSeconds: record.elapsed, session: record.session)
    }
    let summaries = Surface.allCases.map { surface in
      let selected = events.filter { $0.surface == surface }
      let kinds = Set(selected.map(\.kind)).sorted { $0.rawValue < $1.rawValue }
      let intervals = kinds.map { kind in
        let stream = selected.filter { $0.kind == kind }.sorted {
          $0.elapsedSinceFirstRetainedEvent < $1.elapsedSinceFirstRetainedEvent
        }
        var previous: [String: Double] = [:]
        var differences: [Double] = []
        for event in stream {
          if let time = previous[event.session], event.elapsedSinceFirstRetainedEvent >= time {
            differences.append(event.elapsedSinceFirstRetainedEvent - time)
          }
          previous[event.session] = event.elapsedSinceFirstRetainedEvent
        }
        return IntervalSummary(
          kind: kind, count: stream.count,
          meanIntervalSeconds: differences.isEmpty
            ? nil : differences.reduce(0, +) / Double(differences.count))
      }
      let total = clocks[surface.rawValue]?.total ?? 0
      return SurfaceSummary(
        surface: surface, activeSeconds: min(Self.retainedSeconds, total), intervals: intervals)
    }
    return Snapshot(
      explanation:
        "Timing evidence, not screen visibility or paint. Each surface retains up to 30 observed active-feed minutes across sessions (maximum 50000 events). Gaps over 2 seconds and process restarts are not counted. Intervals are grouped by event kind within sessions. Timestamps are Unix seconds. Event elapsed times are relative to the first retained event in that session; raw boot uptime is not exported.",
      surfaces: summaries, events: events)
  }

  func exportJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(snapshot())
  }

  /// Saves `settings` unless told not to, then appends `added`. Each write is applied to `state`
  /// as soon as it succeeds, so memory always matches the files, even when a later write fails.
  /// Unsaved, the next sequence number is in the last appended line, which opening reads back.
  private func commit(
    _ settings: Settings, appending added: [Record] = [], pruning surface: Surface? = nil,
    savingSettings: Bool = true, to state: inout State
  ) throws {
    if savingSettings { try save(settings, to: &state) }
    if !added.isEmpty {
      try append(added)
      state.events.append(contentsOf: added)
      state.lines += added.count
    }
    state.settings = settings
    if let surface, let total = settings.clocks[surface.rawValue]?.total {
      Self.prune(&state.events, surface: surface, total: total, limit: retainedEvents)
    }
    // Events that age out stay in the file, skipped when it's read, until enough build up to
    // rewrite it. A failed rewrite waits for another 1,000 lines before it's tried again.
    if state.lines > 2 * state.events.count + 1000, state.lines >= state.retryCompactionAt {
      do {
        try storage.replace(Self.lines(state.events), eventsURL)
        state.lines = state.events.count
      } catch { state.retryCompactionAt = state.lines + 1000 }
    }
  }

  private func save(_ settings: Settings, to state: inout State) throws {
    do { try storage.replace(JSONEncoder().encode(settings), settingsURL) } catch {
      throw Failure.database
    }
    state.settings = settings
  }

  /// Saves the next sequence number first, since the log that opening reads it back from is
  /// about to go, then empties the log.
  private func erase(_ state: inout State) throws {
    try save(state.settings, to: &state)
    do { try storage.replace(Data(), eventsURL) } catch { throw Failure.database }
    state.events.removeAll()
    state.lines = 0
  }

  /// Appends whole lines, or cuts the file back to where it ended, so a fragment of a failed
  /// write can't run into the next line.
  private func append(_ records: [Record]) throws {
    do {
      if !FileManager.default.fileExists(atPath: eventsURL.path) {
        try storage.replace(Data(), eventsURL)
      }
      let data = try Self.lines(records)
      let handle = try FileHandle(forWritingTo: eventsURL)
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      do { try storage.write(handle, data) } catch {
        try? handle.truncate(atOffset: end)
        throw error
      }
    } catch { throw Failure.database }
  }

  private static func lines(_ records: [Record]) throws -> Data {
    let encoder = JSONEncoder()
    var data = Data()
    for record in records {
      data.append(try encoder.encode(record))
      data.append(0x0A)
    }
    return data
  }

  /// Keeps a surface's events from its last 30 active minutes, and at most `limit` of them.
  /// A surface's elapsed times only grow, so its oldest event shows whether any have expired.
  private static func prune(_ events: inout [Record], surface: Surface, total: Double, limit: Int) {
    let cutoff = total - retainedSeconds
    let expired = events.first { $0.surface == surface }.map { $0.elapsed < cutoff } ?? false
    guard expired || events.count > limit else { return }
    var excess = events.lazy.filter { $0.surface == surface && $0.elapsed >= cutoff }.count - limit
    guard expired || excess > 0 else { return }
    var kept: [Record] = []
    kept.reserveCapacity(events.count)
    for record in events {
      if record.surface == surface, record.elapsed < cutoff || excess > 0 {
        if record.elapsed >= cutoff { excess -= 1 }
      } else {
        kept.append(record)
      }
    }
    events = kept
  }
}
