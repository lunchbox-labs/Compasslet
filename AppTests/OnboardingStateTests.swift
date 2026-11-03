import XCTest
@testable import Compass

@MainActor
final class OnboardingStateTests: XCTestCase {
  private func makeDefaults() throws -> UserDefaults {
    let name = "OnboardingStateTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  func testFirstLaunchStartsTheTourAndFinishingItIsRemembered() throws {
    let defaults = try makeDefaults()
    let onboarding = OnboardingState(defaults: defaults)
    XCTAssertEqual(onboarding.step, .compass)
    onboarding.advance(carPlayConnected: false)
    XCTAssertEqual(onboarding.step, .liveActivity)
    onboarding.advance(carPlayConnected: false)
    XCTAssertEqual(onboarding.step, .shortcuts)
    onboarding.advance(carPlayConnected: false)
    XCTAssertNil(onboarding.step)
    XCTAssertFalse(OnboardingState(defaults: defaults).isTouring)
  }

  func testSkippingEndsTheTourForGood() throws {
    let defaults = try makeDefaults()
    let onboarding = OnboardingState(defaults: defaults)
    onboarding.finish(carPlayConnected: false)
    XCTAssertFalse(onboarding.isTouring)
    XCTAssertFalse(OnboardingState(defaults: defaults).isTouring)
  }

  func testReplayRestartsTheTourWithAFreshTipThatOutlastsRelaunch() throws {
    let defaults = try makeDefaults()
    let onboarding = OnboardingState(defaults: defaults)
    onboarding.finish(carPlayConnected: false)
    let firstTip = onboarding.liveActivityTip.id
    onboarding.replay()
    XCTAssertEqual(onboarding.step, .compass)
    XCTAssertNotEqual(onboarding.liveActivityTip.id, firstTip)
    let relaunched = OnboardingState(defaults: defaults)
    XCTAssertEqual(relaunched.liveActivityTip.id, onboarding.liveActivityTip.id)
  }
}
