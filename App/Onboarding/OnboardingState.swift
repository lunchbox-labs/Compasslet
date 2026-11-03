import Foundation
import TipKit

/// Progress through the first-launch tour and which Live Activity button tip is current.
@MainActor
final class OnboardingState: ObservableObject {
  enum Step: Int, CaseIterable {
    case compass, liveActivity, shortcuts
  }

  static let tourCompletedKey = "onboarding.tourCompleted"
  static let tipGenerationKey = "onboarding.liveActivityTipGeneration"

  /// The tour step on screen, or nil once the tour is finished or skipped.
  @Published private(set) var step: Step?
  @Published private(set) var liveActivityTip: LiveActivityButtonTip
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    step = defaults.bool(forKey: Self.tourCompletedKey) ? nil : .compass
    liveActivityTip = LiveActivityButtonTip(
      generation: defaults.integer(forKey: Self.tipGenerationKey))
  }

  var isTouring: Bool { step != nil }

  func advance(carPlayConnected: Bool) {
    guard let step else { return }
    if let next = Step(rawValue: step.rawValue + 1) {
      self.step = next
    } else {
      finish(carPlayConnected: carPlayConnected)
    }
  }

  /// Ends the tour for good. A tour finished during a CarPlay drive has already pointed out the
  /// button, so the tip for it isn't shown as well.
  func finish(carPlayConnected: Bool) {
    let showedButton = (step?.rawValue ?? -1) >= Step.liveActivity.rawValue
    step = nil
    defaults.set(true, forKey: Self.tourCompletedKey)
    if carPlayConnected, showedButton { liveActivityTip.invalidate(reason: .actionPerformed) }
  }

  /// Starts the tour again and lets the button tip show again. TipKit can only reset its whole
  /// datastore before it's configured, so a fresh tip identifier stands in for a reset.
  func replay() {
    let generation = liveActivityTip.generation + 1
    defaults.set(generation, forKey: Self.tipGenerationKey)
    liveActivityTip = LiveActivityButtonTip(generation: generation)
    step = .compass
  }
}

/// Points at the Live Activity button the first time it appears during a CarPlay drive.
struct LiveActivityButtonTip: Tip {
  let generation: Int

  var id: String { "liveActivityButton.\(generation)" }
  var title: Text { Text("Start or End the Live Activity") }
  var message: Text? {
    Text(
      "It starts on its own when Compasslet opens on CarPlay. Tap here to end it, or to start it again if it’s gone."
    )
  }
  var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}
