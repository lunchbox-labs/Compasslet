import Foundation

struct LatestCourseSnapshot: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable { case waiting, usable, slow, unreliable, unavailable }
  var bearing: Double?
  var status: Status
  var sampleTime: Date
  var source = "vehicleCourseTrueNorth"

  static func unavailable(at date: Date) -> Self {
    Self(bearing: nil, status: .unavailable, sampleTime: date)
  }

  func validated(at now: Date) -> Self {
    guard source == "vehicleCourseTrueNorth", now.timeIntervalSince1970.isFinite,
      sampleTime.timeIntervalSince1970.isFinite, (0...5).contains(now.timeIntervalSince(sampleTime))
    else { return .unavailable(at: now.timeIntervalSince1970.isFinite ? now : .distantPast) }
    guard status == .usable else {
      return Self(bearing: nil, status: status, sampleTime: sampleTime)
    }
    guard let bearing, bearing.isFinite, (0..<360).contains(bearing)
    else { return .unavailable(at: now) }
    return self
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

  func read(now: Date) -> LatestCourseSnapshot {
    guard let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(LatestCourseSnapshot.self, from: data)
    else { return .unavailable(at: now) }
    return value.validated(at: now)
  }
}
