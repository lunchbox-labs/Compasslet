import CompassCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Compass

@Suite @MainActor
struct AppearanceStoreTests {
  @Test func readoutPickerFillsFormRowAndFallsBackWhenNeeded() async throws {
    let name = "readout-layout-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

    func segments(in view: UIView) -> [UISegmentedControl] {
      (view as? UISegmentedControl).map { [$0] }
        ?? view.subviews.flatMap { segments(in: $0) }
    }

    for (width, textSize, hidden, expectsSegments) in [
      (390.0, DynamicTypeSize.large, false, true),
      (744.0, .large, false, true),
      (150.0, .large, false, false),
      (390.0, .accessibility5, false, false),
      (390.0, .large, true, false),
    ] {
      store.update { preferences in
        var value = preferences.effective(for: .phone)
        value.showDirection = !hidden
        value.showDegrees = !hidden
        preferences.setOverride(value, for: .phone)
      }
      let host = UIHostingController(
        rootView: Form {
          Section {
            Picker("Reference", selection: .constant(0)) {
              Text("First").tag(0)
              Text("Second").tag(1)
            }
            .pickerStyle(.segmented)
          }
          Section {
            AppearanceReadoutControl(surface: .phone, store: store)
          }
        }
        .environment(\.dynamicTypeSize, textSize))
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
      window.rootViewController = host
      window.isHidden = false
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      let deadline = ContinuousClock.now + .seconds(3)
      while segments(in: host.view).count != (expectsSegments ? 2 : 1),
        ContinuousClock.now < deadline
      {
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
      }
      host.view.layoutIfNeeded()
      let controls = segments(in: host.view)
      let reference = try #require(controls.first { $0.numberOfSegments == 2 })
      let readout = controls.first { $0.numberOfSegments == 3 }
      #expect((readout != nil) == expectsSegments)
      if expectsSegments {
        let readout = try #require(readout)
        #expect(abs(readout.bounds.width - reference.bounds.width) < 1)
        #expect(readout.bounds.width > 0)
      }
      #expect(store.preferences.effective(for: .phone).hasReadout == !hidden)
    }
  }

  @Test func activityCardsRespectIndependentTimestampChoices() throws {
    let sample = Date(timeIntervalSince1970: 100)
    func render(_ appearance: AppearanceValues, small: Bool, stale: Bool = false) throws -> Data {
      let state = CompassActivityAttributes.ContentState(
        bearing: 45, status: .usable, sampleTime: sample, expiry: nil, appearance: appearance)
      let renderer = ImageRenderer(
        content: CompassActivityCard(state: state, isStale: stale, isSmall: small)
          .frame(width: 300, height: 160)
          .environment(\.dynamicTypeSize, .large)
          .environment(\.colorScheme, .light))
      return try #require(renderer.uiImage?.pngData())
    }
    let original = AppearanceValues()
    var hidden = original
    hidden.lockScreenTimestamp = .hidden
    #expect(try render(original, small: false) != render(hidden, small: false))
    #expect(try render(original, small: true) == render(hidden, small: true))
    hidden.carPlayActivityTimestamp = .hidden
    #expect(try render(original, small: true) != render(hidden, small: true))
    var elapsed = original
    elapsed.lockScreenTimestamp = .elapsed
    elapsed.carPlayActivityTimestamp = .elapsed
    for small in [false, true] {
      #expect(try render(elapsed, small: small) != render(hidden, small: small))
      // Unavailable cards must never expose a timestamp from a stale payload.
      #expect(
        try render(original, small: small, stale: true)
          == render(elapsed, small: small, stale: true)
      )
    }
  }

  @Test func hiddenTimestampCardsShowOnlyTheReading() throws {
    var appearance = AppearanceValues()
    appearance.lockScreenTimestamp = .hidden
    appearance.carPlayActivityTimestamp = .hidden
    let state = CompassActivityAttributes.ContentState(
      bearing: 45, status: .usable, sampleTime: Date(timeIntervalSince1970: 100),
      expiry: nil, appearance: appearance)
    func render(_ view: some View) throws -> Data {
      let renderer = ImageRenderer(
        content: view.frame(width: 300, height: 160)
          .environment(\.dynamicTypeSize, .large)
          .environment(\.colorScheme, .light))
      return try #require(renderer.uiImage?.pngData())
    }
    for small in [false, true] {
      let card = CompassActivityCard(state: state, isSmall: small)
      // Match the card's text proposal and placement; a bare Text can rasterize its trailing
      // degree symbol differently even when the visible content and center are identical.
      let expected: AnyView
      if small {
        let reading = Text(verbatim: "NE 45°")
          .font(Font.title2.weight(.semibold)).monospacedDigit()
          .multilineTextAlignment(.center)
          .lineLimit(1).minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity)
        expected = AnyView(
          reading.padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
      } else {
        // With no line beneath it, the reading may fill the card's whole height.
        let insets = CompassActivityCard.lockScreenInsets
        let height = LockScreenHeight.heights.upperBound - insets.top - insets.bottom
        let reading = ActivityReading(
          presentation: CompassActivityReading(state: state, isStale: false),
          maximumSize: height / ActivityReading.lineHeight
        )
        .frame(maxWidth: .infinity)
        expected = AnyView(
          LockScreenHeight {
            reading.padding(insets).frame(maxWidth: .infinity)
          })
      }
      #expect(try render(card) == render(expected), "small=\(small)")
    }
  }

  @Test func lockScreenCardStaysWithinTheLiveActivityHeightLimits() {
    struct Case {
      var textSize: DynamicTypeSize
      var appearance = AppearanceValues()
      var status = CompassActivityAttributes.Status.usable
      var stale = false
      var diagnostics = false
    }
    var cases: [Case] = []
    for textSize in [DynamicTypeSize.xSmall, .large, .accessibility5] {
      for mode in [ActivityTimestampMode.time, .elapsed, .hidden] {
        // "Move steadily to show travel" is the longest status.
        for status in [CompassActivityAttributes.Status.usable, .slow] {
          for diagnostics in [false, true] {
            var appearance = AppearanceValues()
            appearance.lockScreenTimestamp = mode
            cases.append(
              Case(
                textSize: textSize, appearance: appearance, status: status,
                diagnostics: diagnostics))
          }
        }
      }
    }
    // A custom readout size can be larger or smaller than the system size around it.
    for (system, readout) in [
      (DynamicTypeSize.xSmall, ReadoutTextSize.accessibility5), (.accessibility5, .xSmall),
    ] {
      for status in [CompassActivityAttributes.Status.usable, .slow] {
        var appearance = AppearanceValues()
        appearance.useSystemTextSize = false
        appearance.customTextSize = readout
        cases.append(Case(textSize: system, appearance: appearance, status: status))
      }
    }
    for status in [CompassActivityAttributes.Status.waiting, .unreliable, .unavailable] {
      cases.append(Case(textSize: .accessibility5, status: status))
    }
    cases.append(Case(textSize: .accessibility5, stale: true))

    let sample = Date(timeIntervalSince1970: 100)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    for test in cases {
      let state = CompassActivityAttributes.ContentState(
        bearing: 359, status: test.status, sampleTime: sample, expiry: nil,
        debugUpdateTime: test.diagnostics ? sample : nil, appearance: test.appearance)
      for weight in [LegibilityWeight.regular, .bold] {
        host.rootView = AnyView(
          CompassActivityCard(state: state, isStale: test.stale)
            .environment(\.dynamicTypeSize, test.textSize)
            .environment(\.legibilityWeight, weight))
        // Narrower than any supported banner (a 375-point screen less 22), for margin, and the
        // widest iPhone banners, where the reading is limited by the card's height, not width.
        for width in [298.0, 380, 418] {
          let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
          // The card reports its full height above 160 points, so an overflow shows here.
          #expect(size.height <= 160, "\(test) \(weight) \(width): \(size.height)")
        }
      }
    }
  }

  @Test func lockScreenReadingAlwaysShowsItsLine() throws {
    let sample = Date(timeIntervalSince1970: 100)
    func render(_ mode: ActivityTimestampMode, width: CGFloat, textSize: DynamicTypeSize) throws
      -> Data
    {
      var appearance = AppearanceValues()
      appearance.lockScreenTimestamp = mode
      let state = CompassActivityAttributes.ContentState(
        bearing: 315, status: .usable, sampleTime: sample, expiry: nil, appearance: appearance)
      // At its own height.
      let renderer = ImageRenderer(
        content: CompassActivityCard(state: state)
          .frame(width: width)
          .environment(\.dynamicTypeSize, textSize)
          .environment(\.colorScheme, .light))
      renderer.scale = 3
      return try #require(renderer.uiImage?.pngData())
    }
    for textSize in [DynamicTypeSize.large, .accessibility5] {
      for width in [298.0, 380, 418] {
        // A card without its line would look the same whichever time it shows.
        #expect(
          try render(.time, width: width, textSize: textSize)
            != render(.elapsed, width: width, textSize: textSize), "\(textSize) \(width)")
      }
    }
  }

  @Test func carPlayCardStaysWithinItsSizeAtTheLargestTextSize() {
    let sample = Date(timeIntervalSince1970: 100)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    for weight in [LegibilityWeight.regular, .bold] {
      for mode in [ActivityTimestampMode.time, .elapsed, .hidden] {
        for status in [
          CompassActivityAttributes.Status.usable, .slow, .waiting, .unreliable, .unavailable,
        ] {
          var appearance = AppearanceValues()
          appearance.carPlayActivityTimestamp = mode
          let state = CompassActivityAttributes.ContentState(
            bearing: 359, status: status, sampleTime: sample, expiry: nil,
            appearance: appearance)
          host.rootView = AnyView(
            CompassActivityCard(state: state, isSmall: true)
              .environment(\.dynamicTypeSize, .accessibility5)
              .environment(\.legibilityWeight, weight))
          // One of CarPlay Dashboard's Live Activity sizes. The card reports its full height
          // when its content is taller, so an overflow shows here.
          let size = host.sizeThatFits(in: CGSize(width: 240, height: 78))
          #expect(size.height <= 78, "\(weight) \(mode) \(status): \(size.height)")
        }
      }
    }
  }

  /// CarPlay Dashboard's Live Activity card inside its insets.
  private static let carPlayContent = CGSize(width: 224, height: 70)

  /// The height of a CarPlay reading laid out for the card's content size.
  private func carPlayReadingHeight(
    bearing: Double = 315, appearance: AppearanceValues = AppearanceValues(),
    textSize: DynamicTypeSize = .large, weight: LegibilityWeight = .regular,
    showsTimestamp: Bool = true
  ) -> CGSize {
    let state = CompassActivityAttributes.ContentState(
      bearing: bearing, status: .usable, sampleTime: nil, expiry: nil, appearance: appearance)
    let host = UIHostingController(
      rootView: CarPlayReading(
        presentation: CompassActivityReading(state: state, isStale: false),
        size: Self.carPlayContent, showsTimestamp: showsTimestamp
      ) {
        Text("Last Updated 12:58 PM").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
      }
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.dynamicTypeSize, textSize)
      .environment(\.legibilityWeight, weight))
    return host.sizeThatFits(in: CGSize(width: Self.carPlayContent.width, height: 1000))
  }

  @Test func carPlayReadingFillsItsCardWithoutOutgrowingIt() {
    var custom = AppearanceValues()
    custom.useSystemTextSize = false
    custom.customTextSize = .accessibility5
    var directionFirst = AppearanceValues()
    directionFirst.shortReadout = .direction
    for appearance in [AppearanceValues(), custom, directionFirst] {
      for textSize in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3, .accessibility5] {
        for weight in [LegibilityWeight.regular, .bold] {
          for showsTimestamp in [true, false] {
            let size = carPlayReadingHeight(
              appearance: appearance, textSize: textSize, weight: weight,
              showsTimestamp: showsTimestamp)
            #expect(
              size.height <= Self.carPlayContent.height + 0.5,
              "\(textSize) \(weight) \(showsTimestamp): \(size)")
            #expect(size.width <= Self.carPlayContent.width + 0.5, "\(textSize) \(weight)")
          }
        }
      }
    }
    // Most of the card's height goes to the reading: well over the title size it used to use,
    // which with its line came to about 40 points.
    #expect(carPlayReadingHeight().height > 60)
  }

  @Test func carPlayReadingKeepsOneSizeForEveryDirection() {
    let bearings = Array(stride(from: 0.0, to: 360, by: 22.5)) + [7, 359]
    for textSize in [DynamicTypeSize.large, .accessibility5] {
      let heights = Set(bearings.map { carPlayReadingHeight(bearing: $0, textSize: textSize).height })
      #expect(heights.count == 1, "\(textSize): \(heights)")
    }
  }

  /// The narrowest Lock Screen card's content: a 375-point iPhone with Display Zoom is 320
  /// points wide, less 22 points for the banner and 28 for the card's side insets.
  private static let narrowestLine: CGFloat = 270
  /// A 402-point iPhone's Lock Screen card content, less the same banner and insets.
  private static let typicalLine: CGFloat = 352

  /// The height of a Lock Screen reading on a line of the given width, with room for any size.
  private func readingHeight(
    bearing: Double, appearance: AppearanceValues = AppearanceValues(), width: CGFloat,
    textSize: DynamicTypeSize = .large, weight: LegibilityWeight = .regular
  ) -> CGFloat {
    let state = CompassActivityAttributes.ContentState(
      bearing: bearing, status: .usable, sampleTime: nil, expiry: nil, appearance: appearance)
    let host = UIHostingController(
      rootView: ActivityReading(
        presentation: CompassActivityReading(state: state, isStale: false), maximumSize: 200
      )
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.dynamicTypeSize, textSize)
      .environment(\.legibilityWeight, weight))
    return host.sizeThatFits(in: CGSize(width: width, height: 1000)).height
  }

  @Test func lockScreenReadingKeepsOneSizeForEveryDirection() {
    // Every point, and one-, two- and three-digit angles.
    let bearings = Array(stride(from: 0.0, to: 360, by: 22.5)) + [7, 359]
    var degreesOnly = AppearanceValues()
    degreesOnly.showDirection = false
    var directionOnly = AppearanceValues()
    directionOnly.showDegrees = false
    for appearance in [AppearanceValues(), degreesOnly, directionOnly] {
      for weight in [LegibilityWeight.regular, .bold] {
        for width in [Self.narrowestLine, Self.typicalLine] {
          let heights = Set(
            bearings.map {
              readingHeight(bearing: $0, appearance: appearance, width: width, weight: weight)
            })
          #expect(heights.count == 1, "\(appearance) \(weight) \(width): \(heights)")
        }
      }
    }
  }

  @Test func widestBearingIsAtLeastAsWideAsEveryReading() {
    func width(_ text: String, weight: LegibilityWeight) -> CGFloat {
      let host = UIHostingController(
        rootView: Text(verbatim: text)
          .font(.system(size: 100, weight: .semibold)).monospacedDigit()
          .environment(\.legibilityWeight, weight))
      let unbounded = CGFloat.greatestFiniteMagnitude
      return host.sizeThatFits(in: CGSize(width: unbounded, height: unbounded)).width
    }
    let state = CompassActivityAttributes.ContentState(
      bearing: 0, status: .usable, sampleTime: nil, expiry: nil)
    let widest = CompassActivityReading(state: state, isStale: false).widestBearing
    for weight in [LegibilityWeight.regular, .bold] {
      let limit = width(widest, weight: weight)
      for point in CompassPoint.allCases {
        for degrees in ["0°", "111°", "359°", "888°"] {
          let reading = "\(point.abbreviation) \(degrees)"
          #expect(width(reading, weight: weight) <= limit + 0.5, "\(reading) \(weight)")
        }
      }
    }
  }

  @Test func lockScreenReadingIsFarLargerThanTheLargeTitle() {
    let host = UIHostingController(
      rootView: Text(verbatim: "NE 47°").font(.largeTitle.weight(.semibold)).monospacedDigit()
        .environment(\.dynamicTypeSize, .large))
    let title = host.sizeThatFits(in: CGSize(width: Self.typicalLine, height: 1000)).height
    let reading = readingHeight(bearing: 47, width: Self.typicalLine)
    #expect(reading >= title * 1.6, "\(reading) vs \(title)")
  }

  @Test func lockScreenReadingFollowsSmallerTextSizesOnly() {
    let smaller = [DynamicTypeSize.xSmall, .small, .medium, .large].map {
      readingHeight(bearing: 47, width: Self.typicalLine, textSize: $0)
    }
    #expect(zip(smaller, smaller.dropFirst()).allSatisfy { $0 < $1 }, "\(smaller)")
    // A larger text size can't widen the line.
    #expect(
      readingHeight(bearing: 47, width: Self.typicalLine, textSize: .accessibility5)
        == smaller.last)
  }

  @Test func lockScreenCardFollowsASmallerCustomTextSize() {
    func height(_ appearance: AppearanceValues) -> CGFloat {
      var appearance = appearance
      appearance.lockScreenTimestamp = .hidden
      let state = CompassActivityAttributes.ContentState(
        bearing: 47, status: .usable, sampleTime: nil, expiry: nil, appearance: appearance)
      let host = UIHostingController(
        rootView: CompassActivityCard(state: state).environment(\.dynamicTypeSize, .large))
      return host.sizeThatFits(in: CGSize(width: Self.typicalLine + 28, height: 1000)).height
    }
    var custom = AppearanceValues()
    custom.useSystemTextSize = false
    custom.customTextSize = .xSmall
    #expect(height(custom) < height(AppearanceValues()))
  }

  private func idealWidth(_ view: some View) -> CGFloat {
    let styled = view.font(.caption2).monospacedDigit()
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.dynamicTypeSize, .accessibility5)
      .environment(\.legibilityWeight, .bold)
    let host = UIHostingController(rootView: styled)
    let unbounded = CGFloat.greatestFiniteMagnitude
    return host.sizeThatFits(in: CGSize(width: unbounded, height: unbounded)).width
  }

  @Test func shortLastUpdatedTimeFitsTheNarrowestLockScreenCard() throws {
    // A two-digit hour is the widest 12-hour time, which US English uses.
    let sample = try #require(
      Calendar.current.date(bySettingHour: 12, minute: 58, second: 0, of: .now))
    let width = idealWidth(Text("Updated \(sample, style: .time)"))
    #expect(width * CompassActivityCard.captionScale <= Self.narrowestLine, "\(width)")
  }

  @Test func widestElapsedTimerFitsTheNarrowestLockScreenCard() {
    // The timer never shrinks, and the line drops its label before it would truncate.
    let width = idealWidth(Text(verbatim: ActivityTimestamp.widestTimer))
    #expect(width <= Self.narrowestLine, "\(width)")
  }

  @Test func phonePreviewRendersDialChoicesAndReducedMotionFallback() throws {
    func render(_ value: AppearanceValues, reduceMotion: Bool = false) throws -> UIImage {
      let renderer = ImageRenderer(
        content: AppearancePreview(surface: .phone, appearance: value, reduceMotion: reduceMotion)
          .frame(width: 280)
          .environment(\.dynamicTypeSize, .large)
          .environment(\.colorScheme, .light))
      renderer.scale = 1
      return try #require(renderer.uiImage)
    }
    let initial = AppearanceValues()
    let original = try #require(render(initial).pngData())
    var changed = initial
    changed.minorTicks = .none
    #expect(try #require(render(changed).pngData()) != original)
    changed = initial
    changed.cardinalLabels = .hidden
    #expect(try #require(render(changed).pngData()) != original)
    changed = initial
    changed.rotation = .arrow
    #expect(try #require(render(changed).pngData()) != original)
    changed.showDirection = false
    changed.showDegrees = false
    let steady = try render(changed, reduceMotion: true)
    let restored = try render(changed.requiringReadout(), reduceMotion: true)
    #expect(steady.pngData() == restored.pngData())
    changed.reducedMotionDial = .rotatingDial
    let dial = try render(changed, reduceMotion: true)
    #expect(dial.size.height > steady.size.height)
    // Keep the Dial is a static example, identical to the ordinary dial preview.
    #expect(try render(changed).pngData() == dial.pngData())
  }

  @Test func readoutSelectionPreservesHiddenLegacyValuesUntilExplicitChoice() throws {
    let name = "readout-editor-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    store.update { preferences in
      var hidden = preferences.effective(for: .phone)
      hidden.showDirection = false
      hidden.showDegrees = false
      hidden.rotation = .arrow
      preferences.setOverride(hidden, for: .phone)
    }
    let phone = AppearanceReadoutControl(surface: .phone, store: store)
    #expect(phone.selection == nil)
    #expect(!AppearanceStore.read(from: defaults).effective(for: .phone).hasReadout)
    for mode in ReadoutMode.allCases {
      phone.select(mode)
      #expect(phone.selection == mode)
      let saved = AppearanceStore.read(from: defaults)
      #expect(saved.effective(for: .phone).readoutMode == mode)
      #expect(saved.effective(for: .phone).rotation == .arrow)
      #expect(saved.global.readoutMode == .both)
      #expect(saved.usesGlobal(for: .activity))
    }
    let global = AppearanceReadoutControl(surface: nil, store: store)
    let activity = AppearanceReadoutControl(surface: .activity, store: store)
    global.select(.degrees)
    #expect(activity.selection == .degrees)
    #expect(phone.selection == .both)
    store.update { $0.setUsesGlobal(true, for: .phone) }
    #expect(phone.selection == .degrees)
    global.select(.direction)
    #expect(phone.selection == .direction)
    activity.select(.both)
    #expect(activity.selection == .both)
    #expect(global.selection == .direction)
  }

  @Test func editorSelectionsPersistImmediatelyAndReadCurrentStoreValues() throws {
    let name = "appearance-editor-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    let global = AppearanceOptionEditor(surface: nil, option: .minorTicks, store: store)
    let phone = AppearanceOptionEditor(surface: .phone, option: .rotation, store: store)
    global.binding(\.minorTicks).wrappedValue = .five
    #expect(phone.value.minorTicks == .five)
    #expect(store.preferences.usesGlobal(for: .phone))
    phone.binding(\.rotation).wrappedValue = .arrow
    phone.binding(\.cardinalLabels).wrappedValue = .outside
    phone.binding(\.reducedMotionDial).wrappedValue = .rotatingDial
    let saved = AppearanceStore.read(from: defaults)
    #expect(saved.effective(for: .phone).rotation == .arrow)
    #expect(saved.effective(for: .phone).cardinalLabels == .outside)
    #expect(saved.effective(for: .phone).reducedMotionDial == .rotatingDial)
    #expect(saved.effective(for: .phone).minorTicks == .five)
    #expect(saved.global.rotation == .dial)
    #expect(saved.usesGlobal(for: .activity))
    global.binding(\.minorTicks).wrappedValue = .eight
    #expect(phone.value.minorTicks == .five)
    store.update { $0.setUsesGlobal(true, for: .phone) }
    #expect(phone.value.minorTicks == .eight)
    #expect(phone.value.rotation == .dial)
    // A binding made before a later store update must preserve the newer fields.
    let labels = phone.binding(\.cardinalLabels)
    global.binding(\.minorTicks).wrappedValue = .none
    labels.wrappedValue = .hidden
    #expect(phone.value.minorTicks == .none)
    #expect(phone.value.cardinalLabels == .hidden)
    #expect(
      AppearanceStore(defaults: defaults, legacyDefaults: defaults).preferences == store.preferences
    )
  }

  @Test func savesOverridesAndPreservesUnchangedPreferences() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    store.update { preferences in
      var activity = preferences.effective(for: .activity)
      activity.showDegrees = false
      preferences.setOverride(activity, for: .activity)
    }
    #expect(!AppearanceStore.read(from: defaults).effective(for: .activity).showDegrees)
    let saved = store.preferences
    store.update { _ in }
    #expect(store.preferences == saved)
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences == saved)
  }

  @Test func appThemePersistsAndUpdatesTheAppAndSettingsPresentation() async throws {
    let name = "theme-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.theme == .system)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.overrideUserInterfaceStyle = .dark
    var observed: [String: ColorScheme] = [:]
    let host = UIHostingController(
      rootView:
        ZStack {
          ThemeProbe { observed["compass"] = $0 }
          NavigationStack {
            Form { ThemeProbe { observed["settings"] = $0 } }
          }
        }
        .modifier(AppThemeModifier(store: store)))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    for (theme, expected) in [
      (AppTheme.dark, ColorScheme.dark), (.light, .light), (.system, .dark),
    ] {
      store.update { $0.theme = theme }
      let deadline = ContinuousClock.now + .seconds(3)
      while (observed["compass"] != expected || observed["settings"] != expected),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(observed["compass"] == expected)
      #expect(observed["settings"] == expected)
      #expect(
        AppearanceStore(defaults: defaults, legacyDefaults: defaults).preferences.theme == theme)
    }
    // System must release the override, including subsequent host appearance changes.
    window.overrideUserInterfaceStyle = .light
    let deadline = ContinuousClock.now + .seconds(3)
    while (observed["compass"] != .light || observed["settings"] != .light),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(observed["compass"] == .light)
    #expect(observed["settings"] == .light)
  }

  @Test func everyReadoutSizeMapsToItsDynamicTypeCategoryInOrder() {
    // Choosing a larger custom size must render larger, and the accessibility boundary the
    // slider shows must be the one the system applies.
    let mapped = ReadoutTextSize.allCases.map(\.dynamicTypeSize)
    #expect(mapped == mapped.sorted())
    #expect(Set(mapped).count == mapped.count)
    #expect(ReadoutTextSize.xxxLarge.dynamicTypeSize == .xxxLarge)
    #expect(ReadoutTextSize.accessibility5.dynamicTypeSize == .accessibility5)
    #expect(
      ReadoutTextSize.allCases.allSatisfy {
        $0.isAccessibilitySize == $0.dynamicTypeSize.isAccessibilitySize
      })
    // Every slider step announces a distinct value.
    let titles = ReadoutTextSize.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
  }

  @Test func migratesOnlyExistingPhoneArrowChoiceOnce() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "rotatesCompassDial")
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.effective(for: .phone).rotation == .arrow)
    #expect(store.preferences.usesGlobal(for: .activity))
    store.update { $0.setUsesGlobal(true, for: .phone) }
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences.usesGlobal(for: .phone))
  }
}

private struct ThemeProbe: View {
  @Environment(\.colorScheme) private var scheme
  let observed: (ColorScheme) -> Void

  var body: some View {
    Color.clear.frame(width: 1, height: 1)
      .onChange(of: scheme, initial: true) { _, value in observed(value) }
  }
}
