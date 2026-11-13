import CarPlay
import CompassCore
import Foundation
import Testing
import UIKit
@testable import Compass

@MainActor
struct CarPlayStyleCheckTests {
  private let clock: TestDriveClock
  private let start: Date

  init() {
    let clock = TestDriveClock()
    self.clock = clock
    start = clock.now
  }

  /// The time `intervals` style-check intervals after the start.
  private func after(_ intervals: Double) -> Date {
    start.addingTimeInterval(CarPlayStyleCheck.interval * intervals)
  }

  @Test func activationChecksAtOnceAndAgainAfterEachIdleInterval() {
    var checks: [Date] = []
    let styleCheck = CarPlayStyleCheck(clock: clock) { checks.append(clock.now) }
    styleCheck.activate()
    #expect(checks == [after(0)])
    #expect(clock.pending == [after(1)])
    clock.run(until: after(3))
    #expect(checks == [after(0), after(1), after(2), after(3)])
    #expect(clock.pending == [after(4)])
    styleCheck.resign()
  }

  @Test func aCheckFromAPassRestartsTheWait() {
    var checks: [Date] = []
    let styleCheck = CarPlayStyleCheck(clock: clock) { checks.append(clock.now) }
    styleCheck.activate()
    // Passes closer together than the interval check each time, so no check of its own fires.
    for half in 1...6 {
      clock.run(until: after(Double(half) / 2))
      styleCheck.check()
    }
    #expect(checks == [after(0)] + (1...6).map { after(Double($0) / 2) })
    #expect(clock.pending == [after(4)])
    clock.run(until: after(3.9))
    #expect(checks.count == 7)
    clock.run(until: after(4))
    #expect(checks.last == after(4))
    #expect(checks.count == 8)
    styleCheck.resign()
  }

  @Test func resigningStopsTheChecksWhileAPassStillChecks() {
    var checks: [Date] = []
    let styleCheck = CarPlayStyleCheck(clock: clock) { checks.append(clock.now) }
    styleCheck.activate()
    clock.run(until: after(0.5))
    styleCheck.resign()
    #expect(clock.pending == [])
    clock.run(until: after(10))
    #expect(checks == [after(0)])
    // A pass on the inactive scene checks once and sets nothing to follow.
    styleCheck.check()
    #expect(checks == [after(0), after(10)])
    #expect(clock.pending == [])
    // Becoming active again resumes the checks.
    styleCheck.activate()
    #expect(checks == [after(0), after(10), after(10)])
    #expect(clock.pending == [after(11)])
    styleCheck.resign()
  }

  @Test func activatingTwiceKeepsOneCheckWaiting() {
    var checks = 0
    let styleCheck = CarPlayStyleCheck(clock: clock) { checks += 1 }
    styleCheck.activate()
    clock.run(until: after(0.5))
    styleCheck.activate()
    #expect(checks == 2)
    #expect(clock.pending == [after(1.5)])
    styleCheck.resign()
  }

  @Test func droppingTheCheckCancelsTheOneWaiting() {
    var styleCheck: CarPlayStyleCheck? = CarPlayStyleCheck(clock: clock) {}
    styleCheck?.activate()
    #expect(clock.pending == [after(1)])
    styleCheck = nil
    #expect(clock.pending == [])
  }

  /// With no drive, the car turning dark or changing scale reaches the dial within one interval
  /// though nothing else happens on the scene, and checks with nothing changed draw nothing.
  @Test func anIdleSceneFollowsTheCarsStyleAndScaleAndRedrawsOnlyOnAChange() throws {
    func car(_ style: UIUserInterfaceStyle, scale: CGFloat) -> UITraitCollection {
      UITraitCollection { traits in
        traits.userInterfaceStyle = style
        traits.displayScale = scale
      }
    }
    let screen = CarPlayCompassTemplate()
    var traits = car(.light, scale: 2)
    var redraws = 0
    let styleCheck = CarPlayStyleCheck(clock: clock) {
      if screen.refresh(traits: traits) { redraws += 1 }
    }
    let ended = CarPlayPresentation(
      presentation: TravelPresentation(sample: nil, status: .waiting), setup: .ready,
      driving: false, now: clock.now)
    screen.update(ended, traits: traits)
    let light = try #require(screen.template.listHeader?.thumbnail.image.renderedPixels)
    styleCheck.activate()
    clock.run(until: after(3))
    #expect(redraws == 0)
    traits = car(.dark, scale: 2)
    clock.run(until: after(4))
    #expect(redraws == 1)
    let dark = try #require(screen.template.listHeader?.thumbnail.image.renderedPixels)
    #expect(dark != light)
    #expect(screen.template.listHeader?.bodyVariants.map(\.string) == [ended.status])
    clock.run(until: after(6))
    #expect(redraws == 1)
    traits = car(.dark, scale: 3)
    clock.run(until: after(7))
    #expect(redraws == 2)
    // Once the scene resigns, a change waits for the next activation or pass.
    styleCheck.resign()
    traits = car(.light, scale: 3)
    clock.run(until: after(20))
    #expect(redraws == 2)
    styleCheck.activate()
    #expect(redraws == 3)
    styleCheck.resign()
  }
}
