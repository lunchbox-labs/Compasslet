import SwiftUI
import UIKit

/// Carries the Live Activity button's frame up to the tour, which highlights it in place.
struct LiveActivityControlBoundsKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// The first-launch tour, drawn over the compass screen. The Live Activity step dims everything
/// except the real button in its bottom-right corner.
struct WelcomeTourOverlay: View {
  @ObservedObject var onboarding: OnboardingState
  /// The button's frame in this view's coordinates, while the button is on screen.
  let buttonFrame: CGRect?
  let carPlayConnected: Bool
  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    if let step = onboarding.step {
      GeometryReader { proxy in
        let spotlight = step == .liveActivity ? buttonFrame?.insetBy(dx: -8, dy: -8) : nil
        ZStack {
          scrim(size: proxy.size, cutout: spotlight)
          if let spotlight {
            Circle().strokeBorder(Color.white, lineWidth: 2)
              .frame(width: spotlight.width, height: spotlight.height)
              .position(x: spotlight.midX, y: spotlight.midY)
              .accessibilityHidden(true)
          }
          if let spotlight {
            VStack(spacing: 0) {
              Spacer(minLength: 16)
              card(step).frame(maxWidth: .infinity, alignment: .trailing)
              Pointer()
                .fill(Self.cardBackground)
                .frame(width: 22, height: 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, max(20, min(spotlight.midX - 16 - 11, proxy.size.width - 64)))
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, max(0, proxy.size.height - spotlight.minY + 6))
          } else {
            card(step).padding(16)
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(.isModal)
      .accessibilityAction(.escape) { onboarding.finish(carPlayConnected: carPlayConnected) }
      .onAppear { titleFocused = true }
      .onChange(of: onboarding.step) { titleFocused = true }
    }
  }

  private static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

  /// Covers the screen, safe areas included, with a hole over the highlighted button.
  private func scrim(size: CGSize, cutout: CGRect?) -> some View {
    Path { path in
      path.addRect(CGRect(origin: .zero, size: size).insetBy(dx: -400, dy: -400))
      if let cutout { path.addEllipse(in: cutout) }
    }
    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
    .contentShape(Rectangle())
    .accessibilityHidden(true)
  }

  private func card(_ step: OnboardingState.Step) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      ViewThatFits(in: .vertical) {
        explanation(step)
        ScrollView { explanation(step) }
      }
      controls(step)
    }
    .padding(20)
    .frame(maxWidth: 440)
    .background(Self.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
  }

  private func explanation(_ step: OnboardingState.Step) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      artwork(step)
      Text(title(step))
        .font(.title3.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      Text(message(step))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func artwork(_ step: OnboardingState.Step) -> some View {
    switch step {
    case .compass:
      Image(systemName: "safari").font(.largeTitle).foregroundStyle(.tint)
        .accessibilityHidden(true)
    case .liveActivity:
      EmptyView()
    case .shortcuts:
      HStack(spacing: 8) {
        Image(systemName: "play.circle")
        Image(systemName: "stop.circle")
      }
      .font(.largeTitle).foregroundStyle(.tint)
      .accessibilityHidden(true)
    }
  }

  private func controls(_ step: OnboardingState.Step) -> some View {
    let isLast = step == OnboardingState.Step.allCases.last
    let position = Text("\(step.rawValue + 1) of \(OnboardingState.Step.allCases.count)")
      .font(.footnote).foregroundStyle(.secondary)
    let skip = Button("Skip") { onboarding.finish(carPlayConnected: carPlayConnected) }
      .frame(minHeight: 44)
      .opacity(isLast ? 0 : 1)
      .disabled(isLast)
      .accessibilityHidden(isLast)
    let next = Button(isLast ? "Done" : "Next") {
      onboarding.advance(carPlayConnected: carPlayConnected)
    }
    .buttonStyle(.borderedProminent)
    .frame(minHeight: 44)
    return ViewThatFits(in: .horizontal) {
      HStack {
        skip
        Spacer(minLength: 8)
        position
        Spacer(minLength: 8)
        next
      }
      VStack(alignment: .leading, spacing: 8) {
        position
        next
        if !isLast { skip }
      }
    }
  }

  private func title(_ step: OnboardingState.Step) -> String {
    switch step {
    case .compass: "Welcome to Compasslet"
    case .liveActivity: "Live Activity Button"
    case .shortcuts: "Siri and Shortcuts"
    }
  }

  private func message(_ step: OnboardingState.Step) -> String {
    switch step {
    case .compass:
      return
        "Compasslet shows your heading from magnetic north on iPhone, and your travel direction on CarPlay."
    case .liveActivity:
      let shown =
        "This button appears here only while Compasslet is open on CarPlay. Tap it to start or end the Live Activity that shows your travel direction on the Lock Screen and in the Dynamic Island. The Live Activity also starts on its own when you open Compasslet on CarPlay."
      return carPlayConnected ? shown : shown + " Until then, the button stays hidden."
    case .shortcuts:
      return
        "Start Live Activity and End Live Activity are in the Shortcuts app too, so an automation can run them when CarPlay connects. You can also ask Siri to “Start Compasslet Live Activity.” A Live Activity started this way ends after a minute unless you open Compasslet on CarPlay."
    }
  }
}

/// The small triangle under the tour card that points down at the button.
private struct Pointer: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}
