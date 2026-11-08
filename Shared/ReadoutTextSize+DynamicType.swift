import CompassCore
import SwiftUI

// Shared with the Live Activity extension, which sizes its readouts from these.
extension AppearanceValues {
  func readoutTextSize(system: DynamicTypeSize) -> DynamicTypeSize {
    useSystemTextSize ? system : customTextSize.dynamicTypeSize
  }
}

extension ReadoutTextSize {
  var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .xSmall: .xSmall
    case .small: .small
    case .medium: .medium
    case .large: .large
    case .xLarge: .xLarge
    case .xxLarge: .xxLarge
    case .xxxLarge: .xxxLarge
    case .accessibility1: .accessibility1
    case .accessibility2: .accessibility2
    case .accessibility3: .accessibility3
    case .accessibility4: .accessibility4
    case .accessibility5: .accessibility5
    }
  }

  var title: String {
    switch self {
    case .xSmall: "Extra Small"
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Default"
    case .xLarge: "Extra Large"
    case .xxLarge: "Extra Extra Large"
    case .xxxLarge: "Extra Extra Extra Large"
    case .accessibility1: "Accessibility Medium"
    case .accessibility2: "Accessibility Large"
    case .accessibility3: "Accessibility Extra Large"
    case .accessibility4: "Accessibility Extra Extra Large"
    case .accessibility5: "Accessibility Extra Extra Extra Large"
    }
  }
}
