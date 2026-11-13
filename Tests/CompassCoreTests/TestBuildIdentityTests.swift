import CompassCore
import Testing

private let commit = "0123456789abcdef0123456789abcdef01234567"

@Test func testBuildsShowTheirVersionBuildAndShortCommit() throws {
  let identity = try #require(
    TestBuildIdentity(infoDictionary: [
      "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "42.1",
      TestBuildIdentity.commitKey: commit,
    ]))
  #expect(identity.versionAndBuild == "1.0.1 (42.1)")
  #expect(identity.shortCommit == "0123456")
  #expect(identity.commit == commit)
}

@Test func buildsWithoutARecordedCommitShowNothing() {
  // Release candidates, App Store downloads and local builds have no commit key.
  #expect(
    TestBuildIdentity(infoDictionary: [
      "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "42.1",
    ]) == nil)
}

@Test func malformedValuesShowNothing() {
  let badCommits = [
    "", "0123456", commit.uppercased(), String(commit.dropLast()) + "g", commit + "0",
  ]
  for badCommit in badCommits {
    #expect(TestBuildIdentity(version: "1.0.1", build: "42.1", commit: badCommit) == nil)
  }
  #expect(TestBuildIdentity(version: "", build: "42.1", commit: commit) == nil)
  #expect(TestBuildIdentity(version: "1.0.1", build: "", commit: commit) == nil)
  #expect(
    TestBuildIdentity(infoDictionary: [
      "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "42.1",
      TestBuildIdentity.commitKey: 42,
    ]) == nil)
}
