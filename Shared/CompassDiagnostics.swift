import Foundation
import Observation
import Synchronization

/// Local timing evidence only. An event never proves that CarPlay painted a frame.
///
/// Only the app's own process writes it: from the main actor on drive heartbeats and CarPlay
/// renders, and from Live Activity updates off it. Every call runs under one lock and returns
/// once written, so a session's start, pause and total land in the order the calls were made.
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

  static let shared: CompassDiagnostics? = {
    #if os(iOS)
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
  /// One stored event. Surface and kind stay strings, so a line written by a version that
  /// records another surface or kind still reads, and is left out of the export.
  private struct Record: Codable {
    let sequence: Int64
    let surface: String
    let kind: String
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
    var lastObservation: [Surface: (uptime: Double, active: Bool)] = [:]

    /// Adds an event to the surface's current session with the next sequence number.
    mutating func add(
      _ surface: Surface, _ kind: Kind, wall: Double, uptime: Double, clock: Clock
    ) -> Record {
      let record = Record(
        sequence: settings.nextSequence, surface: surface.rawValue, kind: kind.rawValue, wall: wall,
        uptime: uptime, elapsed: clock.total, session: clock.session)
      settings.nextSequence += 1
      events.append(record)
      return record
    }
  }

  let directory: URL
  private let settingsURL: URL
  private let eventsURL: URL
  private let process = UUID().uuidString
  private let registrar = ObservationRegistrar()
  private let state: Mutex<State>

  /// Opens the store in `directory`, which must exist. A settings file that can't be read
  /// leaves the store unopened rather than starting over.
  init(directory: URL) throws {
    let settingsURL = directory.appendingPathComponent("settings.json")
    let eventsURL = directory.appendingPathComponent("events.jsonl")
    var settings = Settings()
    var data = Data()
    do {
      if FileManager.default.fileExists(atPath: settingsURL.path) {
        settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
      }
      if FileManager.default.fileExists(atPath: eventsURL.path) {
        data = try Data(contentsOf: eventsURL)
      }
    } catch { throw Failure.database }
    // A line that doesn't decode, such as one cut short when the app stopped mid-write, is
    // dropped rather than making the whole log unreadable.
    let stored = data.split(separator: 0x0A)
    let decoder = JSONDecoder()
    var events = stored.compactMap { try? decoder.decode(Record.self, from: Data($0)) }
    events.sort { $0.sequence < $1.sequence }
    settings.nextSequence = max(settings.nextSequence, (events.last?.sequence ?? 0) + 1)
    for (surface, clock) in settings.clocks {
      CompassDiagnostics.prune(&events, surface: surface, total: clock.total)
    }
    var state = State(settings: settings, events: events, lines: stored.count)
    // Rewriting drops what was left out, and ends the file on a whole line for the next append.
    if events.count != stored.count || !(data.isEmpty || data.last == 0x0A) {
      do { try CompassDiagnostics.rewrite(events, to: eventsURL) } catch { throw Failure.database }
      state.lines = events.count
    }
    self.directory = directory
    self.settingsURL = settingsURL
    self.eventsURL = eventsURL
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
        var next = state
        next.settings.enabled = value
        if value {
          // Resume on the next lifecycle tick, never from an old wall-clock timestamp.
          for surface in next.settings.clocks.keys { next.settings.clocks[surface]?.active = false }
        } else {
          next.settings.clocks.removeAll()
          next.events.removeAll()
        }
        next.lastObservation.removeAll()
        // Turning it off erases the events before saving the switch, so a failed erase leaves
        // Debug Mode on with its log.
        try commit(next, to: &state, replacingEvents: !value)
      }
    }
  }

  /// Called by existing lifecycle ticks, not by an extra timer. Gaps are not assumed active.
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
      let clock = Clock(
        total: total, wall: wall, uptime: uptime, owner: process, session: session, active: active)
      var next = state
      next.settings.clocks[surface.rawValue] = clock
      var added: [Record] = []
      if active && !continuing {
        added.append(next.add(surface, .started, wall: wall, uptime: uptime, clock: clock))
      } else if !active && wasActive {
        added.append(next.add(surface, .paused, wall: wall, uptime: uptime, clock: clock))
      }
      try commit(next, to: &state, appending: added, pruning: surface)
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
      var next = state
      let event = next.add(surface, kind, wall: wall, uptime: uptime, clock: clock)
      // The sequence number isn't saved here: the next launch takes it from the last line.
      try commit(next, to: &state, appending: [event], pruning: surface, savingSettings: false)
      return true
    }
  }

  func clear() throws {
    try state.withLock { state in
      var next = state
      next.settings.clocks.removeAll()
      next.events.removeAll()
      next.lastObservation.removeAll()
      try commit(next, to: &state, replacingEvents: true)
    }
  }

  func snapshot() throws -> Snapshot {
    let (records, clocks) = state.withLock { ($0.events, $0.settings.clocks) }
    var origins: [String: Double] = [:]
    for record in records {
      origins[record.session] = min(origins[record.session] ?? record.uptime, record.uptime)
    }
    let events = records.compactMap { record -> Event? in
      // A surface or kind this version doesn't record, such as a removed one, is left out.
      guard let surface = Surface(rawValue: record.surface), let kind = Kind(rawValue: record.kind)
      else { return nil }
      let origin = origins[record.session, default: record.uptime]
      return Event(
        sequence: record.sequence, surface: surface, kind: kind, timestamp: record.wall,
        elapsedSinceFirstRetainedEvent: record.uptime - origin, activeSeconds: record.elapsed,
        session: record.session)
    }
    let summaries = Surface.allCases.map { surface in
      let selected = events.filter { $0.surface == surface }
      let kinds = Set(selected.map(\.kind.rawValue)).sorted()
      let intervals = kinds.compactMap { name -> IntervalSummary? in
        guard let kind = Kind(rawValue: name) else { return nil }
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

  /// How many active seconds of events each surface keeps, and how many events at most.
  private static let retainedSeconds: Double = 1800
  private static let retainedEvents = 50_000
  private static let writeOptions: Data.WritingOptions = [
    .atomic, .completeFileProtectionUntilFirstUserAuthentication,
  ]

  /// Writes `next` to the files and only then makes it current, so a failed write leaves the
  /// store as it was apart from the skip state `observe` keeps in memory.
  private func commit(
    _ next: State, to state: inout State, appending added: [Record] = [],
    pruning surface: Surface? = nil, replacingEvents: Bool = false, savingSettings: Bool = true
  ) throws {
    var next = next
    do {
      if replacingEvents {
        try Self.rewrite(next.events, to: eventsURL)
        next.lines = next.events.count
      }
      if savingSettings {
        try JSONEncoder().encode(next.settings).write(to: settingsURL, options: Self.writeOptions)
      }
      if !added.isEmpty {
        try append(added)
        next.lines += added.count
      }
    } catch { throw Failure.database }
    if let surface, let total = next.settings.clocks[surface.rawValue]?.total {
      Self.prune(&next.events, surface: surface.rawValue, total: total)
    }
    // Events that age out stay in the file, left out when it's read, until enough build up to
    // rewrite it.
    if next.lines > 2 * next.events.count + 1000,
      (try? Self.rewrite(next.events, to: eventsURL)) != nil
    {
      next.lines = next.events.count
    }
    state = next
  }

  private func append(_ records: [Record]) throws {
    if !FileManager.default.fileExists(atPath: eventsURL.path) {
      try Self.rewrite([], to: eventsURL)
    }
    let handle = try FileHandle(forWritingTo: eventsURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Self.lines(records))
  }

  private static func rewrite(_ records: [Record], to url: URL) throws {
    try lines(records).write(to: url, options: writeOptions)
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

  /// Keeps a surface's events from its last 30 active minutes, and at most 50,000 of them.
  private static func prune(_ events: inout [Record], surface: String, total: Double) {
    events.removeAll { $0.surface == surface && $0.elapsed < total - retainedSeconds }
    var excess = events.lazy.filter { $0.surface == surface }.count - retainedEvents
    guard excess > 0 else { return }
    var kept: [Record] = []
    kept.reserveCapacity(events.count - excess)
    for record in events {
      if excess > 0, record.surface == surface { excess -= 1 } else { kept.append(record) }
    }
    events = kept
  }
}
