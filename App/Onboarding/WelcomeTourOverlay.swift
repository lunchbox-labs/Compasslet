import SwiftUI
import UIKit

struct LiveActivityControlBoundsKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

struct WelcomeTourOverlay: View {
  @ObservedObject var onboarding: OnboardingState
  /// The button's frame in this view's coordinates, while the button is on screen.
  let buttonFrame: CGRect?
  let carPlayConnected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Whether the scrolling explanation has text below the card's edge, which fades out to show it.
  @State private var moreBelow = false
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
      .accessibilityAction(.escape) { finish() }
      .onAppear { titleFocused = true }
      .onChange(of: onboarding.step) { titleFocused = true }
    }
  }

  private static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

  private func scrim(size: CGSize, cutout: CGRect?) -> some View {
    Path { path in
      // Reaches past the bounds so the dimming covers the safe areas too.
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
          .scrollIndicatorsFlash(onAppear: true)
          .scrollIndicatorsFlash(trigger: step)
          .onScrollGeometryChange(for: Bool.self) { scroll in
            scroll.visibleRect.maxY < scroll.contentSize.height - 1
          } action: { _, more in
            moreBelow = more
          }
          .mask {
            VStack(spacing: 0) {
              Color.black
              LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: moreBelow ? 40 : 0)
            }
          }
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
    let skip = Button(action: finish) {
      Text("Skip").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
    .opacity(isLast ? 0 : 1)
    .disabled(isLast)
    .accessibilityHidden(isLast)
    let next = Button(isLast ? "Done" : "Next") {
      animated { onboarding.advance(carPlayConnected: carPlayConnected) }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    return ViewThatFits(in: .horizontal) {
      // Fixed sizes make the row fall back to the stack rather than
      // wrap "Next" at large text sizes.
      HStack {
        skip
        Spacer(minLength: 8)
        position.fixedSize()
        Spacer(minLength: 8)
        next.fixedSize()
      }
      VStack(alignment: .leading, spacing: 8) {
        position
        next
        if !isLast { skip }
      }
    }
  }

  private func finish() {
    animated { onboarding.finish(carPlayConnected: carPlayConnected) }
  }

  /// Animates the compass screen too, which gains or loses the button between steps.
  private func animated(_ change: () -> Void) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25), change)
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
        "When you open Compasslet on CarPlay, the Live Activity starts on its own and shows your travel direction on the Lock Screen and in the Dynamic Island. Until CarPlay disconnects, this button appears in the bottom-right corner so you can end it or start it again."
      return carPlayConnected
        ? shown : shown + " You’re seeing a preview. It hides when you move on."
    case .shortcuts:
      return
        "Start Live Activity and End Live Activity are also in the Shortcuts app for your automations, and you can ask Siri to “Start Compasslet Live Activity”. Starting it this way opens Compasslet on iPhone, so do it while parked. It ends after a minute unless you open Compasslet on CarPlay."
    }
  }
}

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
