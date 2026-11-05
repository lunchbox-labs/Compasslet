import CompassCore
import SwiftUI
import TipKit
import UIKit

@main
struct CompassApp: App {
  @UIApplicationDelegateAdaptor(CompassAppDelegate.self) private var appDelegate

  init() {
    // Without a datastore, the Live Activity button tip never shows; the app works without it.
    try? Tips.configure()
  }

  var body: some Scene {
    WindowGroup {
      CompassView(drive: appDelegate.drive)
        .modifier(AppThemeModifier(store: .shared))
        // Switches stay system green unless tinted. The Settings sheet repeats both modifiers,
        // so it follows them while it's open.
        .tint(Color.accentColor)
    }
  }
}

/// Applies the preference to this app presentation only, including its Settings navigation.
struct AppThemeModifier: ViewModifier {
  @ObservedObject var store: AppearanceStore

  func body(content: Content) -> some View {
    content.preferredColorScheme(store.preferences.theme.colorScheme)
  }
}

extension AppTheme {
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

extension Color {
  /// The brand's primary action fill and its label, from the organisation's colour guidance.
  /// White on this pink is only 2.14:1, so primary actions keep the dark label in both
  /// appearances.
  static let brandActionFill = Color("PrimaryActionFill")
  static let brandActionLabel = Color("PrimaryActionLabel")
  /// The label on a button filled with the accent: white on the light-mode plum (6.75:1), dark
  /// on the dark-mode pink (8.09:1).
  static let confirmActionLabel = Color("ConfirmActionLabel")
}

/// The brand's primary action button: a pink capsule with a dark label. On light backgrounds
/// the pink alone is too pale to outline the button, so the darker accent draws its edge; in
/// dark mode the accent and the fill match. Drawn here rather than tinting a system style, so
/// the label colour and the pressed state don't depend on how the system renders a tint.
struct PrimaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PrimaryActionCapsule(label: configuration.label, isPressed: configuration.isPressed)
  }
}

private struct PrimaryActionCapsule<Label: View>: View {
  let label: Label
  let isPressed: Bool
  @Environment(\.isEnabled) private var isEnabled
  // Grow with the text so the capsule keeps its proportions at large sizes.
  @ScaledMetric(relativeTo: .body) private var horizontalInset = 20
  @ScaledMetric(relativeTo: .body) private var verticalInset = 14

  var body: some View {
    label
      .font(.body.weight(.semibold))
      .foregroundStyle(Color.brandActionLabel)
      .padding(.horizontal, horizontalInset)
      .padding(.vertical, verticalInset)
      .frame(minHeight: 50)
      .background(Color.brandActionFill, in: Capsule())
      .overlay { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
      // Darkens on press rather than fading, so the dark label keeps its contrast.
      .overlay { Capsule().fill(Color.black.opacity(isPressed ? 0.12 : 0)) }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
  }
}
