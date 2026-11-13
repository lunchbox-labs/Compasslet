import Foundation

/// Where Compasslet's source code lives, for the app's links to it.
public enum SourceRepository {
  private static let address = "https://github.com/lunchbox-labs/compasslet"

  /// The repository's page on GitHub.
  public static var url: URL? { URL(string: address) }

  /// The GitHub page for one commit, given its full SHA.
  static func commitURL(_ commit: String) -> URL? {
    URL(string: "\(address)/commit/\(commit)")
  }
}
