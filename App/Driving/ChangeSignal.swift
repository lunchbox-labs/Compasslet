import Foundation

/// Wakes the tasks waiting for something to change. Each waiter wakes once, at the next
/// `signal()`, at its deadline or when its task is cancelled, whichever comes first, and then
/// checks again what it waits for.
@MainActor
final class ChangeSignal {
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  /// How many tasks are waiting, so tests can check that none is left behind.
  var waitingCount: Int { waiters.count }

  /// Waits until the next `signal()`, until `deadline` passes or until the task is cancelled.
  /// A signal sent before the wait starts doesn't end it.
  func wait(until deadline: ContinuousClock.Instant) async {
    let id = UUID()
    let timeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
      self?.resume(id)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiters[id] = $0 }
    } onCancel: {
      Task { @MainActor [weak self] in self?.resume(id) }
    }
    timeout.cancel()
  }

  /// Wakes every task waiting now.
  func signal() {
    let woken = waiters.values
    waiters.removeAll()
    for waiter in woken { waiter.resume() }
  }

  private func resume(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume()
  }
}
