import Foundation

/// Which build a TestFlight test build is, shown in Settings so testers can tell exactly what they
/// have installed. Publish records the source commit only in test builds, so release candidates,
/// App Store downloads and local builds have no identity and show nothing.
public struct TestBuildIdentity: Hashable, Sendable {
  /// The Info.plist key Publish writes a test build's full commit SHA under.
  public static let commitKey = "CompassletTestBuildCommit"

  public let version: String
  public let build: String
  public let commit: String

  public init?(version: String, build: String, commit: String) {
    guard !version.isEmpty, !build.isEmpty, commit.count == 40,
      commit.allSatisfy({ "0123456789abcdef".contains($0) })
    else { return nil }
    self.version = version
    self.build = build
    self.commit = commit
  }

  /// Reads a bundle's Info.plist values, such as `Bundle.main.infoDictionary`.
  public init?(infoDictionary: [String: Any]) {
    guard let version = infoDictionary["CFBundleShortVersionString"] as? String,
      let build = infoDictionary["CFBundleVersion"] as? String,
      let commit = infoDictionary[Self.commitKey] as? String
    else { return nil }
    self.init(version: version, build: build, commit: commit)
  }

  /// The version and build number as TestFlight lists them, such as “1.0.1 (42.1)”.
  public var versionAndBuild: String { "\(version) (\(build))" }

  /// The commit shortened as Git and GitHub show it.
  public var shortCommit: String { String(commit.prefix(7)) }

  /// The commit's page on GitHub.
  public var commitURL: URL? { SourceRepository.commitURL(commit) }
}
