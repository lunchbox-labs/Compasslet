import Foundation

/// Deletes the retired timeline widget's last sample without touching shared preferences or logs.
enum RetiredWidgetData {
  static func remove(from sharedDirectory: URL) throws {
    let directory = sharedDirectory.appendingPathComponent("LatestCourse", isDirectory: true)
    do {
      try FileManager.default.removeItem(at: directory)
    } catch CocoaError.fileNoSuchFile {
      // A fresh installation or an earlier successful cleanup has nothing to remove.
    }
  }
}
