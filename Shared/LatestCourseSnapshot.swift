import Foundation

struct LatestCourseSnapshot: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable {
    case waiting, usable, historical, slow, unreliable, unavailable
  }
  var bearing: Double?
  var status: Status
  var sampleTime: Date
  var source = "vehicleCourseTrueNorth"

  static func unavailable(at date: Date) -> Self {
    Self(bearing: nil, status: .unavailable, sampleTime: date)
  }

  func validated(at now: Date) -> Self {
    guard source == "vehicleCourseTrueNorth", now.timeIntervalSince1970.isFinite,
      sampleTime.timeIntervalSince1970.isFinite,
      (0...maximumAge).contains(now.timeIntervalSince(sampleTime))
    else { return .unavailable(at: now.timeIntervalSince1970.isFinite ? now : .distantPast) }
    guard status == .usable || status == .historical else {
      return Self(bearing: nil, status: status, sampleTime: sampleTime)
    }
    guard let bearing, bearing.isFinite, (0..<360).contains(bearing)
    else { return .unavailable(at: now) }
    var result = self
    result.status =
      status == .historical || now.timeIntervalSince(sampleTime) > 5 ? .historical : .usable
    return result
  }

  /// Historical data is never a current compass reading; retain only one sample for two minutes.
  private var maximumAge: TimeInterval { status == .usable || status == .historical ? 120 : 5 }
  var retentionExpiry: Date { sampleTime.addingTimeInterval(maximumAge) }

  /// Boundaries are inclusive, so transition immediately after the final valid instant.
  func transitionDates(after date: Date) -> [Date] {
    [expiry.addingTimeInterval(0.001), retentionExpiry.addingTimeInterval(0.001)]
      .filter { $0 > date }.reduce(into: []) { result, value in
        if !result.contains(value) { result.append(value) }
      }
  }

  var expiry: Date { sampleTime.addingTimeInterval(5) }
}

struct LatestCourseStore: Sendable {
  static let shared: LatestCourseStore? = {
    #if os(iOS)
      guard
        var directory = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: "group.dev.lunchbox-labs.carplay-compass")
      else { return nil }
      directory.appendPathComponent("LatestCourse", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return LatestCourseStore(url: directory.appendingPathComponent("latest.json"))
      } catch { return nil }
    #else
      return nil
    #endif
  }()

  let url: URL

  /// One writer replaces one snapshot; readers see either complete version, never an append log.
  func write(_ value: LatestCourseSnapshot, now: Date) throws {
    let data = try JSONEncoder().encode(value.validated(at: now))
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
    var file = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try file.setResourceValues(values)
  }

  enum ReadOutcome { case success, missing, corrupt, failure }

  func read(now: Date, report: ((ReadOutcome, LatestCourseSnapshot) -> Void)? = nil)
    -> LatestCourseSnapshot
  {
    let value: LatestCourseSnapshot
    let outcome: ReadOutcome
    var observed: LatestCourseSnapshot?
    do {
      let data = try Data(contentsOf: url)
      do {
        let decoded = try JSONDecoder().decode(LatestCourseSnapshot.self, from: data)
        observed = decoded
        value = decoded.validated(at: now)
        outcome = .success
      } catch {
        value = .unavailable(at: now)
        outcome = .corrupt
      }
    } catch {
      value = .unavailable(at: now)
      outcome = (error as? CocoaError)?.code == .fileReadNoSuchFile ? .missing : .failure
    }
    report?(outcome, observed ?? value)
    return value
  }
}
