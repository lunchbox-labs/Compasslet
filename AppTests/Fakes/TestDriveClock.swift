import Foundation
@testable import Compass

/// A clock that moves only when a test sets it, and runs the timers that have come due when
/// asked.
final class TestDriveClock: DriveClock {
  private typealias Entry = (id: Int, date: Date, fire: @MainActor () -> Void)
  var now: Date
  private var timers: [Entry] = []
  private var lastID = 0

  nonisolated init(now: Date = Date(timeIntervalSince1970: 1_000)) { self.now = now }

  func timer(at date: Date, _ fire: @escaping @MainActor () -> Void) -> DriveTimer {
    lastID += 1
    let id = lastID
    timers.append((id, date, fire))
    return DriveTimer { [weak self] in self?.timers.removeAll { $0.id == id } }
  }

  /// When the timers still to fire are due, earliest first.
  var pending: [Date] { timers.map(\.date).sorted() }

  /// Runs each timer due by now once, earliest first. Timers set meanwhile wait for the next call.
  func fireDue() {
    let due = timers.filter { $0.date <= now }.sorted(by: Self.earlier).map(\.id)
    for id in due {
      guard let index = timers.firstIndex(where: { $0.id == id }) else { continue }
      timers.remove(at: index).fire()
    }
  }

  /// Moves time on to `date`, running each timer at its own time on the way, earliest first.
  func run(until date: Date) {
    while let next = timers.filter({ $0.date <= date }).min(by: Self.earlier) {
      timers.removeAll { $0.id == next.id }
      if next.date > now { now = next.date }
      next.fire()
    }
    now = date
  }

  nonisolated private static func earlier(_ first: Entry, _ second: Entry) -> Bool {
    (first.date, first.id) < (second.date, second.id)
  }
}
