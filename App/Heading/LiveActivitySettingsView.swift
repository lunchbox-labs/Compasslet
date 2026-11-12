import CompassCore
import SwiftUI

/// How often a drive updates its Live Activity, and when the drive ends on its own after the car
/// leaves.
struct LiveActivitySettingsView: View {
  var store: LiveActivitySettingsStore = .shared

  var body: some View {
    Form {
      Section {
        choices(LiveActivityRefreshRate.allCases, keyPath: \.refreshRate, title: \.title)
      } header: {
        Text("Refresh Rate")
      } footer: {
        Text(
          "How often the Live Activity gets a new direction during a drive. iOS decides when the Lock Screen and CarPlay show each update. Compasslet’s own CarPlay screen isn’t affected."
        )
      }
      Section {
        choices(LiveActivityAutoStop.allCases, keyPath: \.autoStop, title: \.title)
      } header: {
        Text("Auto-Stop")
      } footer: {
        Text(
          "How long a drive continues after CarPlay disconnects. Until it ends, Compasslet keeps using your location, which uses more battery. Drives always end after eight hours."
        )
      }
    }
    .navigationTitle("Live Activity")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// One row per choice, with a checkmark on the selected one, as on the appearance editors.
  private func choices<Value: Hashable>(
    _ choices: [Value], keyPath: WritableKeyPath<LiveActivityPreferences, Value>,
    title: KeyPath<Value, String>
  ) -> some View {
    ForEach(choices, id: \.self) { choice in
      let selected = store.preferences[keyPath: keyPath] == choice
      Button {
        store.update { $0[keyPath: keyPath] = choice }
      } label: {
        HStack {
          Text(choice[keyPath: title])
            .foregroundStyle(Color.primary)
          Spacer()
          if selected {
            Image(systemName: "checkmark").accessibilityHidden(true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
  }
}

extension LiveActivityRefreshRate {
  var title: String {
    switch self {
    case .everySecond: "Every Second"
    case .everyFiveSeconds: "Every 5 Seconds"
    case .everyFifteenSeconds: "Every 15 Seconds"
    case .everyThirtySeconds: "Every 30 Seconds"
    }
  }
}

extension LiveActivityAutoStop {
  var title: String {
    switch self {
    case .afterOneMinute: "After 1 Minute"
    case .afterFiveMinutes: "After 5 Minutes"
    case .afterFifteenMinutes: "After 15 Minutes"
    case .never: "Never"
    }
  }
}
