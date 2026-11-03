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
