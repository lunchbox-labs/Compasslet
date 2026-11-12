import Testing
@testable import Compass

/// Far enough away that only a signal or cancellation ends a wait within the time limit.
private let hour = Duration.seconds(60 * 60)

// A signal that never comes, or a cancellation that never resumes, would leave a test waiting for
// the hour-long deadline, so the time limit fails it first.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct ChangeSignalTests {
  /// Starts a task that waits on `signal` with the hour-long deadline.
  private func startWaiting(on signal: ChangeSignal) -> Task<Void, Never> {
    Task { await signal.wait(until: ContinuousClock.now + hour) }
  }

  /// Lets the waiting tasks run until `count` of them wait.
  private func untilWaiting(_ count: Int, on signal: ChangeSignal) async {
    while signal.waitingCount < count { await Task.yield() }
  }

  @Test func signalWakesTheWaiter() async {
    let signal = ChangeSignal()
    let waiter = startWaiting(on: signal)
    await untilWaiting(1, on: signal)
    signal.signal()
    await waiter.value
    #expect(signal.waitingCount == 0)
  }

  @Test func deadlineWakesTheWaiter() async {
    let signal = ChangeSignal()
    let deadline = ContinuousClock.now + .milliseconds(50)
    await signal.wait(until: deadline)
    #expect(ContinuousClock.now >= deadline)
    #expect(signal.waitingCount == 0)
  }

  @Test func passedDeadlineEndsTheWait() async {
    let signal = ChangeSignal()
    await signal.wait(until: ContinuousClock.now - .seconds(1))
    #expect(signal.waitingCount == 0)
  }

  @Test func earlierSignalDoesNotEndALaterWait() async {
    let signal = ChangeSignal()
    signal.signal()
    let deadline = ContinuousClock.now + .milliseconds(50)
    await signal.wait(until: deadline)
    #expect(ContinuousClock.now >= deadline)
  }

  @Test func cancellationResumesAndRemovesTheWaiter() async {
    let signal = ChangeSignal()
    let waiter = startWaiting(on: signal)
    await untilWaiting(1, on: signal)
    waiter.cancel()
    await waiter.value
    #expect(signal.waitingCount == 0)
    // A later signal finds nothing left to resume.
    signal.signal()
  }

  @Test func cancellationBeforeTheWaitStartsResumes() async {
    let signal = ChangeSignal()
    // The task runs on the main actor, so it's cancelled before it starts waiting.
    let waiter = startWaiting(on: signal)
    waiter.cancel()
    await waiter.value
    #expect(signal.waitingCount == 0)
  }

  @Test func signalWakesEveryWaiter() async {
    let signal = ChangeSignal()
    let waiters = (0..<3).map { _ in startWaiting(on: signal) }
    await untilWaiting(3, on: signal)
    signal.signal()
    for waiter in waiters { await waiter.value }
    #expect(signal.waitingCount == 0)
  }

  @Test func cancellingOneWaiterLeavesTheOthersWaiting() async {
    let signal = ChangeSignal()
    let cancelled = startWaiting(on: signal)
    let others = (0..<2).map { _ in startWaiting(on: signal) }
    await untilWaiting(3, on: signal)
    cancelled.cancel()
    await cancelled.value
    #expect(signal.waitingCount == 2)
    signal.signal()
    for waiter in others { await waiter.value }
    #expect(signal.waitingCount == 0)
  }
}
