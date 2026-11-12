import SwiftUI
import UIKit

struct WelcomeTourOverlay: View {
  let onboarding: OnboardingState
  /// The button's frame in this view's coordinates, while the button is on screen.
  let buttonFrame: CGRect?
  let carPlayConnected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
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
                .overlay {
                  if colorScheme == .dark {
                    PointerEdge().stroke(Color(uiColor: .separator), lineWidth: 1)
                  }
                }
                .frame(width: 22, height: 11)
                // Overlaps the card by a point so the fill covers the card's edge at its base.
                .offset(y: -1)
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
    // When the step doesn't fit, the whole card scrolls with its controls, as an alert does at
    // the largest text sizes, so the explanation gets the card's full height to show in.
    ViewThatFits(in: .vertical) {
      cardContent(step)
      ScrollingCardContent { cardContent(step) }.id(step)
    }
    .frame(maxWidth: 440)
    .background(Self.cardBackground, in: cardShape)
    .clipShape(cardShape)
    .overlay {
      if colorScheme == .dark {
        cardShape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
      }
    }
  }

  private func cardContent(_ step: OnboardingState.Step) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      explanation(step)
      controls(step)
    }
    .padding(20)
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 20, style: .continuous)
  }

  private func explanation(_ step: OnboardingState.Step) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      artwork(step)
      heading(step)
        .font(.title3.bold())
        .fontDesign(.rounded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(step))
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      Text(message(step))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The step's title. When the welcome title wraps, the app name gets a line of its own and
  /// shrinks a little if it must, so the largest text sizes never hyphenate it.
  @ViewBuilder private func heading(_ step: OnboardingState.Step) -> some View {
    if step == .compass {
      ViewThatFits(in: .horizontal) {
        Text(title(step))
        VStack(alignment: .leading, spacing: 0) {
          Text("Welcome to")
          Text(verbatim: "Compasslet").lineLimit(1).minimumScaleFactor(0.75)
        }
      }
    } else {
      Text(title(step))
    }
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
    .buttonStyle(PrimaryActionButtonStyle())
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
        "When you open Compasslet on CarPlay, the Live Activity starts on its own and shows your travel direction on the Lock Screen and in the Dynamic Island. Until CarPlay disconnects, this button appears beside Settings in the bottom-right corner so you can end it or start it again."
      return carPlayConnected
        ? shown : shown + " You’re seeing a preview. It hides when you move on."
    case .shortcuts:
      return
        "Start Live Activity and End Live Activity are also in the Shortcuts app for your automations, and you can ask Siri to “Start Compasslet Live Activity”. If your iPhone asks you to unlock it, do it while parked. Once CarPlay disconnects, the Live Activity ends after the Auto-Stop time you choose in Settings, a minute by default. If CarPlay doesn’t connect, it ends after a minute."
    }
  }
}

/// A tour step too long for the card, which fades at the bottom edge while more of it is below,
/// so it doesn't read as if the sentence just stops.
private struct ScrollingCardContent<Content: View>: View {
  @ViewBuilder let content: Content
  // Starts true: the card only scrolls when its step overflows, and it opens at the top.
  @State private var moreBelow = true

  var body: some View {
    ScrollView { content }
      .scrollIndicatorsFlash(onAppear: true)
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

/// The pointer's two slanted sides, outlined in dark mode to match the card's edge.
private struct PointerEdge: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    }
  }
}
