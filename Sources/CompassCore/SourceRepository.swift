import Foundation

/// Where Compasslet's source code lives, for the app's links to it.
public enum SourceRepository {
  /// The repository's web address on GitHub.
  public static let address = "https://github.com/lunchbox-labs/compasslet"

  public static var url: URL? { URL(string: address) }

  /// The GitHub page for one commit, given its full SHA.
  public static func commitURL(_ commit: String) -> URL? {
    URL(string: "\(address)/commit/\(commit)")
  }
}
