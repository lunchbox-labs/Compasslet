import CompassCore
import SwiftUI

struct AppearanceSettingsView: View {
  var body: some View {
    Form {
      Section("Defaults") {
        NavigationLink("Global Appearance") { AppearanceDetailView(surface: nil) }
      }
      Section {
        ForEach(AppearanceSurface.allCases, id: \.self) { surface in
          NavigationLink(surface.title) { AppearanceDetailView(surface: surface) }
        }
      } header: {
        Text("Surfaces")
      } footer: {
        Text("Fullscreen CarPlay uses the system’s layout and text sizes.")
      }
    }
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct AppearanceDetailView: View {
  let surface: AppearanceSurface?
  @ObservedObject private var store = AppearanceStore.shared

  private var value: AppearanceValues {
    surface.map { store.preferences.effective(for: $0) } ?? store.preferences.global
  }
  private var followsGlobal: Bool {
    surface.map { store.preferences.usesGlobal(for: $0) } ?? false
  }
  private var requiresReadout: Bool { surface == nil || surface == .activity }

  var body: some View {
    Form {
      if let surface {
        Section {
          Toggle(
            "Use global settings",
            isOn: Binding(
              get: { followsGlobal },
              set: { follow in store.update { $0.setUsesGlobal(follow, for: surface) } }
            ))
        } footer: {
          Text(
            "Turn off to customize this surface. Turning on replaces its custom appearance with global settings."
          )
        }
      }
      Section("Example") {
        AppearancePreview(surface: surface, appearance: value)
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        if followsGlobal {
          Text("Following Global Appearance")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        }
      }
      if !followsGlobal {
        Section {
          Toggle("Show direction", isOn: binding(\.showDirection))
            .disabled(requiresReadout && value.showDirection && !value.showDegrees)
          Toggle("Show degrees", isOn: binding(\.showDegrees))
            .disabled(requiresReadout && value.showDegrees && !value.showDirection)
        } header: {
          Text("Readout")
        } footer: {
          if requiresReadout {
            Text(
              surface == nil
                ? "Keep direction or degrees visible for Live Activity. To hide both on a dial, customize that surface."
                : "Keep direction or degrees visible in Live Activity.")
          }
        }
        Section {
          Toggle("Use System Text Size", isOn: binding(\.useSystemTextSize))
          if !value.useSystemTextSize {
            VStack(spacing: 8) {
              Text("Custom text size")
              Slider(
                value: Binding(
                  get: { Double(value.customTextSize.rawValue) },
                  set: { selection in
                    binding(\.customTextSize).wrappedValue =
                      ReadoutTextSize(rawValue: Int(selection.rounded())) ?? .large
                  }),
                in: 0...Double(ReadoutTextSize.allCases.count - 1), step: 1
              ) {
                Text("Custom text size")
              } minimumValueLabel: {
                Text("A").font(.caption).accessibilityHidden(true)
              } maximumValueLabel: {
                Text("A").font(.title2).accessibilityHidden(true)
              }
              .accessibilityValue(value.customTextSize.title)
              Text(value.customTextSize.title).font(.caption).foregroundStyle(.secondary)
              if value.customTextSize.isAccessibilitySize {
                Text("Accessibility size")
                  .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
              }
            }
            .frame(maxWidth: .infinity)
          }
        } header: {
          Text("Text Size")
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              value.hasReadout
                ? (value.useSystemTextSize
                  ? "The compass readout follows the system text size for each surface. Other interface text continues to follow Dynamic Type."
                  : "Choose a size for the compass readout, up to the largest accessibility size. Other interface text continues to follow Dynamic Type.")
                : "Text size is kept while both center readouts are hidden.")
            if surface != .phone {
              Text(
                "In the Dynamic Island the readout stops at Extra Extra Extra Large; the Lock Screen uses the full range."
              )
            }
          }
        }
        .disabled(!value.hasReadout)
        if surface != .activity {
          Section {
            Picker("Minor ticks per quarter", selection: binding(\.minorTicks)) {
              ForEach(MinorTicks.allCases, id: \.self) { count in
                Text("\(count.rawValue)").tag(count)
              }
            }
            Picker("Cardinal labels", selection: binding(\.labels)) {
              Text("Inside").tag(CardinalLabels.inside)
              Text("Outside").tag(CardinalLabels.outside)
              Text("Hidden").tag(CardinalLabels.hidden)
            }
            Picker("Rotation", selection: binding(\.rotation)) {
              Text("Rotate dial").tag(DialRotation.dial)
              Text("Rotate arrow").tag(DialRotation.arrow)
            }
          } header: {
            Text("Dial")
          } footer: {
            Text(
              "Minor ticks are the small marks between cardinal directions. Four major ticks remain. Cardinal labels are N, E, S, and W."
            )
          }
          .pickerStyle(.navigationLink)
        }
        Section {
          Button(surface == nil ? "Reset Global Appearance" : "Reset Appearance") {
            store.update { preferences in
              if let surface {
                preferences.setUsesGlobal(true, for: surface)
              } else {
                preferences.setGlobal(AppearanceValues())
              }
            }
          }
        }
      }
    }
    .navigationTitle(surface?.title ?? "Global Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceValues, Value>) -> Binding<Value>
  {
    Binding(
      get: { value[keyPath: keyPath] },
      set: { newValue in
        var changed = value
        changed[keyPath: keyPath] = newValue
        store.update { preferences in
          if let surface {
            preferences.setOverride(changed, for: surface)
          } else {
            preferences.setGlobal(changed)
          }
        }
      })
  }
}

private struct AppearancePreview: View {
  let surface: AppearanceSurface?
  let appearance: AppearanceValues
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(spacing: 16) {
      if surface != .activity {
        VStack(spacing: 4) {
          Text("Phone · Magnetic north")
            .font(.caption2).foregroundStyle(.secondary)
          CompassDial(
            bearing: 45, appearance: appearance,
            showsReadout: false
          )
          .frame(height: 180)
          if appearance.hasReadout {
            ViewThatFits(in: .horizontal) {
              PhoneCompassReadout(bearing: 45, appearance: appearance)
              PhoneCompassReadout(bearing: 45, appearance: appearance, maximumTextSize: 40)
            }
            .dynamicTypeSize(appearance.readoutTextSize(system: dynamicTypeSize))
          }
        }
        .padding().frame(maxWidth: 260)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
      }
      if surface == nil || surface == .activity {
        VStack(spacing: 8) {
          CompassReadout(bearing: 45, appearance: appearance.requiringReadout())
          Text("Travel · True north").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Example: northeast, 45 degrees")
  }
}

extension AppearanceSurface {
  fileprivate var title: String {
    switch self {
    case .phone: "iPhone Compass"
    case .activity: "Live Activity"
    }
  }
}
