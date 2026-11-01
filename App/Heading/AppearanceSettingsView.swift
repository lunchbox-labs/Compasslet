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

  var body: some View {
    Form {
      if surface == nil {
        Section {
          Picker(
            "Theme",
            selection: Binding(
              get: { store.preferences.theme },
              set: { theme in store.update { $0.theme = theme } }
            )
          ) {
            Text("System").tag(AppTheme.system)
            Text("Light").tag(AppTheme.light)
            Text("Dark").tag(AppTheme.dark)
          }
          .pickerStyle(.segmented)
        } header: {
          Text("Theme")
        } footer: {
          Text("Applies to the iPhone app. CarPlay and Live Activity use the system appearance.")
        }
      }
      if let surface {
        Section {
          Toggle(
            "Use Global Settings",
            isOn: Binding(
              get: { followsGlobal },
              set: { follow in store.update { $0.setUsesGlobal(follow, for: surface) } }
            ))
        } footer: {
          Text(
            "Turning on replaces custom settings with global settings."
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
          AppearanceReadoutControl(surface: surface, store: store)
        } header: {
          Text("Readout")
        } footer: {
          if value.readoutMode == nil {
            Text("This saved appearance hides the readout. Choose a mode to show it.")
          }
        }
        Section {
          Toggle("Use System Text Size", isOn: binding(\.useSystemTextSize))
          if !value.useSystemTextSize {
            VStack(spacing: 8) {
              Text("Custom Text Size")
              Slider(
                value: Binding(
                  get: { Double(value.customTextSize.rawValue) },
                  set: { selection in
                    binding(\.customTextSize).wrappedValue =
                      ReadoutTextSize(rawValue: Int(selection.rounded())) ?? .large
                  }),
                in: 0...Double(ReadoutTextSize.allCases.count - 1), step: 1
              ) {
                Text("Custom Text Size")
              } minimumValueLabel: {
                Text("A").font(.caption).accessibilityHidden(true)
              } maximumValueLabel: {
                Text("A").font(.title2).accessibilityHidden(true)
              }
              .accessibilityValue(value.customTextSize.title)
              Text(value.customTextSize.title).font(.caption).foregroundStyle(.secondary)
              if value.customTextSize.isAccessibilitySize {
                Text("Accessibility Size")
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
                ? "Changes the compass readout only."
                : "Show a readout to change its text size.")
            if surface != .phone {
              Text(
                "Dynamic Island limits larger text sizes; the Lock Screen supports the full range."
              )
            }
          }
        }
        .disabled(!value.hasReadout)
        if surface != .activity {
          Section {
            editorLink(.minorTicks)
            editorLink(.labels)
            editorLink(.rotation)
          } header: {
            Text("Dial")
          }
          Section {
            editorLink(.reduceMotion)
          } header: {
            Text("Reduce Motion")
          } footer: {
            Text(
              "Used when Reduce Motion is on. Choose a text-only reading or a dial with reduced movement."
            )
          }
        }
        Section {
          Button(surface == nil ? "Reset Global Appearance" : "Reset Appearance") {
            store.update { preferences in
              if let surface {
                preferences.setUsesGlobal(true, for: surface)
              } else {
                preferences.setGlobal(AppearanceValues())
                preferences.theme = .system
              }
            }
          }
        }
      }
    }
    .navigationTitle(surface?.title ?? "Global Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func editorLink(_ option: AppearanceOption) -> some View {
    NavigationLink {
      AppearanceOptionEditor(surface: surface, option: option, store: store)
    } label: {
      LabeledContent(option.title, value: option.selectionTitle(in: value))
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceValues, Value>) -> Binding<Value>
  {
    store.binding(keyPath, for: surface)
  }
}

struct AppearanceReadoutControl: View {
  let surface: AppearanceSurface?
  @ObservedObject var store: AppearanceStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var selection: ReadoutMode? {
    let value = surface.map { store.preferences.effective(for: $0) } ?? store.preferences.global
    return value.readoutMode
  }

  var body: some View {
    if let selection, !dynamicTypeSize.isAccessibilitySize {
      ViewThatFits(in: .horizontal) {
        ReadoutPickerLayout {
          Picker(
            "Readout",
            selection: Binding(get: { self.selection ?? selection }, set: select)
          ) {
            ForEach(ReadoutMode.allCases, id: \.self) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }
        menu
      }
    } else {
      menu
    }
  }

  private var menu: some View {
    Menu {
      ForEach(ReadoutMode.allCases, id: \.self) { mode in
        Button {
          select(mode)
        } label: {
          if selection == mode {
            Label(mode.title, systemImage: "checkmark")
          } else {
            Text(mode.title)
          }
        }
        .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
      }
    } label: {
      LabeledContent("Readout", value: selection?.title ?? "Choose Readout")
    }
  }

  func select(_ mode: ReadoutMode) {
    store.update { preferences in
      var changed = surface.map { preferences.effective(for: $0) } ?? preferences.global
      changed.setReadoutMode(mode)
      if let surface {
        preferences.setOverride(changed, for: surface)
      } else {
        preferences.setGlobal(changed)
      }
    }
  }
}

// Keep the intrinsic width for ViewThatFits, but give the visible picker the full row.
private struct ReadoutPickerLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let picker = subviews.first else { return .zero }
    let ideal = picker.sizeThatFits(.unspecified)
    let width = max(ideal.width, proposal.width ?? ideal.width)
    let size = picker.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    return CGSize(width: width, height: size.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

private extension ReadoutMode {
  var title: String {
    switch self {
    case .direction: "Direction"
    case .degrees: "Degrees"
    case .both: "Both"
    }
  }
}

enum AppearanceOption: CaseIterable {
  case minorTicks, labels, rotation, reduceMotion

  var title: String {
    switch self {
    case .minorTicks: "Minor Ticks per Quarter"
    case .labels: "Cardinal Labels"
    case .rotation: "Rotation"
    case .reduceMotion: "With Reduce Motion"
    }
  }

  func selectionTitle(in value: AppearanceValues) -> String {
    switch self {
    case .minorTicks: "\(value.minorTicks.rawValue)"
    case .labels:
      switch value.labels {
      case .inside: "Inside"
      case .outside: "Outside"
      case .hidden: "Hidden"
      }
    case .rotation: value.rotation == .dial ? "Rotate Dial" : "Rotate Arrow"
    case .reduceMotion:
      value.reducedMotionDial == .steadyReadout ? "Steady Reading" : "Keep the Dial"
    }
  }
}

struct AppearanceOptionEditor: View {
  let surface: AppearanceSurface?
  let option: AppearanceOption
  @ObservedObject var store: AppearanceStore

  var value: AppearanceValues {
    surface.map { store.preferences.effective(for: $0) } ?? store.preferences.global
  }

  var body: some View {
    Form {
      Section {
        AppearancePreview(
          surface: .phone, appearance: value, reduceMotion: option == .reduceMotion
        )
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } header: {
        Text("Example")
      } footer: {
        if option == .reduceMotion {
          Text("This example shows Reduce Motion turned on.")
        }
      }
      Section(option.title) {
        switch option {
        case .minorTicks:
          choices(MinorTicks.allCases, keyPath: \.minorTicks)
        case .labels:
          choices(CardinalLabels.allCases, keyPath: \.labels)
        case .rotation:
          choices(DialRotation.allCases, keyPath: \.rotation)
        case .reduceMotion:
          choices(ReducedMotionDial.allCases, keyPath: \.reducedMotionDial)
        }
      }
    }
    .navigationTitle(option.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func choices<Value: Hashable>(
    _ choices: [Value], keyPath: WritableKeyPath<AppearanceValues, Value>
  ) -> some View {
    ForEach(choices, id: \.self) { choice in
      let selected = value[keyPath: keyPath] == choice
      Button {
        binding(keyPath).wrappedValue = choice
      } label: {
        HStack {
          Text(choiceTitle(choice, keyPath: keyPath))
            .foregroundStyle(.primary)
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

  private func choiceTitle<Value>(
    _ choice: Value, keyPath: WritableKeyPath<AppearanceValues, Value>
  ) -> String {
    var candidate = value
    candidate[keyPath: keyPath] = choice
    return option.selectionTitle(in: candidate)
  }

  func binding<Value>(_ keyPath: WritableKeyPath<AppearanceValues, Value>) -> Binding<Value> {
    store.binding(keyPath, for: surface)
  }
}

struct AppearancePreview: View {
  let surface: AppearanceSurface?
  let appearance: AppearanceValues
  var reduceMotion = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var phone: PhoneCompassPresentation {
    PhoneCompassPresentation(appearance: appearance, reduceMotion: reduceMotion)
  }

  private var accessibilityDescription: String {
    var parts = ["Example"]
    if surface != .activity {
      parts.append("Phone, magnetic north")
      parts.append(phone.showsDial ? "Dial visible" : "Dial hidden")
      if phone.appearance.showDirection { parts.append("northeast") }
      if phone.appearance.showDegrees { parts.append("45 degrees") }
      if !phone.appearance.hasReadout { parts.append("Readout hidden") }
    }
    if surface == nil || surface == .activity {
      let activity = appearance.requiringReadout()
      parts.append("Travel, true north")
      if activity.showDirection { parts.append("northeast") }
      if activity.showDegrees { parts.append("45 degrees") }
    }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    VStack(spacing: 16) {
      if surface != .activity {
        VStack(spacing: 4) {
          Text("Phone · Magnetic North")
            .font(.caption2).foregroundStyle(.secondary)
          if phone.showsDial {
            CompassDial(
              bearing: 45, appearance: phone.appearance,
              showsReadout: false
            )
            .frame(height: 180)
          }
          if phone.appearance.hasReadout {
            ViewThatFits(in: .horizontal) {
              PhoneCompassReadout(bearing: 45, appearance: phone.appearance)
              PhoneCompassReadout(bearing: 45, appearance: phone.appearance, maximumTextSize: 40)
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
          Text("Travel · True North").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityDescription)
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

@MainActor
private extension AppearanceStore {
  func binding<Value>(
    _ keyPath: WritableKeyPath<AppearanceValues, Value>, for surface: AppearanceSurface?
  ) -> Binding<Value> {
    func current() -> AppearanceValues {
      surface.map { preferences.effective(for: $0) } ?? preferences.global
    }
    return Binding(
      get: { current()[keyPath: keyPath] },
      set: { newValue in
        var changed = current()
        changed[keyPath: keyPath] = newValue
        self.update { preferences in
          if let surface {
            preferences.setOverride(changed, for: surface)
          } else {
            preferences.setGlobal(changed)
          }
        }
      })
  }
}
