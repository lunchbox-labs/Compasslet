import Foundation
import TipKit

@MainActor
final class OnboardingState: ObservableObject {
  enum Step: Int, CaseIterable {
    case compass, liveActivity, shortcuts
  }

  static let tourCompletedKey = "onboarding.tourCompleted"
  static let tipGenerationKey = "onboarding.liveActivityTipGeneration"

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

  /// A tour finished while CarPlay is connected has already pointed out the button, so its tip
  /// isn't shown as well.
  func finish(carPlayConnected: Bool) {
    let showedButton = (step?.rawValue ?? -1) >= Step.liveActivity.rawValue
    step = nil
    defaults.set(true, forKey: Self.tourCompletedKey)
    if carPlayConnected, showedButton { liveActivityTip.invalidate(reason: .actionPerformed) }
  }

  /// TipKit can only reset its whole datastore before it's configured, so a fresh tip identifier
  /// stands in for a reset.
  func replay() {
    let generation = liveActivityTip.generation + 1
    defaults.set(generation, forKey: Self.tipGenerationKey)
    liveActivityTip = LiveActivityButtonTip(generation: generation)
    step = .compass
  }
}

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
