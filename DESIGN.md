# Compasslet design

Compasslet follows the Lunchbox Labs [design foundation](https://github.com/lunchbox-labs/.github/blob/main/brand/foundation.md)
and [organisation colours](https://github.com/lunchbox-labs/.github/blob/main/brand/colors.md).
The [iOS guide](https://github.com/lunchbox-labs/.github/blob/main/brand/ios.md) maps those rules to
the app; the [web guide](https://github.com/lunchbox-labs/.github/blob/main/brand/web.md) maps them
to the docs site. Read the relevant guide before changing a surface.

Those documents own the shared tokens, contrast checks, type, spacing, shape and motion.
This file records Compasslet's implementation mapping and platform constraints. It does not
define a second palette. Shared changes belong in the organisation guidance first; record a
local exception here only with its reason.

## iPhone app

The iOS guide is the implementation target. Adding this document does not apply the remaining
visual changes to the app.

| Surface or role | Compasslet mapping |
| --- | --- |
| Compass background | `systemBackground` in `App/Heading/CompassView.swift` |
| Settings and tour surfaces | System grouped backgrounds and fills; keep `Form` and native list insets |
| Essential text and readings | System `label` / SwiftUI `.primary` |
| Supporting text | System `secondaryLabel` / `.secondary`; check Increase Contrast as the iOS guide requires |
| Dividers | System `separator`; decorative dial marks may use tertiary or quaternary styles |
| Links, toggles and selected controls | `AccentColor` in `App/Assets.xcassets`, using the iOS guide's strong pink |
| Main filled action | `PrimaryActionFill` and `PrimaryActionLabel` in the asset catalog |
| Label on a filled toolbar confirm | `ConfirmActionLabel` in the asset catalog, paired with `AccentColor` |

Keep iOS semantic neutrals in both appearances. The web's tinted page, surface and text tokens
do not replace them, and a system black background is not a design defect. Asset names above
are the shared iOS mapping, including colours that still need to be added by implementation PRs.

- Apply the rounded bold display voice to the main reading and onboarding or permission titles.
  Navigation titles, settings and body text keep SF Pro. Preserve the person's readout size
  choices and use monospaced digits for changing readings. Casing follows [AGENTS.md](AGENTS.md).
- Use the foundation's spacing steps for custom layout and `@ScaledMetric` beside text. Native
  margins and list insets follow iOS rather than the web. The iOS guide owns card corners,
  capsules, glass controls, target sizes and press states.
- The dial in `Shared/CompassDial.swift` keeps a red north marker, distinguished by shape as well
  as colour. Check the small “N” separately for text contrast; red is functional, not a brand
  accent. Essential direction information must remain readable without colour.
- Keep the compass's reduced-motion choice: steady text or a dial with reduced movement.
  Values crossing north must not animate the long way round. New custom transitions follow
  the foundation's timing and no-bounce rule, with a short fade or no movement under Reduce Motion.
- The Live Activity button's tip is a local exception to supporting text: it sits on an opaque
  grouped background with its message in `label`, because the system popover's material let the
  large heading show through, and `secondaryLabel` is under 4.5:1 on the light background.

## Live Activity and CarPlay

These system-hosted surfaces have constraints beyond an ordinary iPhone screen.

- `Shared/CompassActivityCard.swift` keeps the Lock Screen and small mirrored card text-only.
  On the Lock Screen and in the expanded Dynamic Island, the single-line reading is as large as
  the widest reading allows, at one size for every direction, so it never jumps as the direction
  changes. Smaller text sizes make it smaller; larger ones can't widen the line. CarPlay's
  reading fills the card's height the same way, at one size for every direction, and never
  drops below the size of the Title 2 text style. Both show “Last Updated” and a sample time when
  available. At large text sizes the label shortens to “Updated”, and the elapsed timer, which
  never shrinks, drops it. Size these for a 270pt line, the card on a 375pt iPhone with
  Display Zoom. Keep the Lock Screen card within its 160pt height limit.
- The Lock Screen card is see-through: it draws its own black tint in the dark look and white
  tint in the light look, with the system tint clear, so the wallpaper shows behind it.
  `LockScreenBackdrop` in `CompassCore` sets the tint's opacity and the secondary text, which is
  the primary colour at reduced opacity, and its tests keep that text at 4.5:1 or better over
  any solid wallpaper colour. Reduce Transparency gives a solid card and Increase Contrast a
  more opaque one.
- Other Live Activity backgrounds, in CarPlay, the Apple Watch Smart Stack and the Dynamic
  Island, belong to the system. Keep semantic primary and secondary text rather than copying
  web neutrals into the extension. Its compact readings use the system's text styles for
  legibility in the available space.
- The Lock Screen card's 14pt side inset and 2pt reading-to-caption spacing are local compact
  layout exceptions, not extra steps in the app-wide spacing scale.
- `CompassActivity/CompassActivityWidget.swift` caps the compact Dynamic Island readout at
  `.xxxLarge`, and the expanded island's reading is at most 44pt, because its regions have
  fixed bounds. Lock Screen and small-card layouts must
  still be checked through the accessibility sizes. Preserve the full spoken reading and
  freshness information when visible text is shortened.
- `App/CarPlay/CarPlayCompassTemplate.swift` leaves template layout, text and backgrounds to
  CarPlay. Resolve custom dial colours and dimensions using the car's traits, not the phone's.
  Keep travel direction distinct from the phone's magnetic heading and from a live reading.
- CarPlay's small card has a fixed size. When the reading and Last Updated can't both fit at
  large text sizes, it shows the reading alone, and a status shrinks to fit rather than grow
  past the card.
- CarPlay and the Apple Watch Smart Stack share the small card. At the largest text sizes its
  reading may have room for only direction or degrees; the If Both Don’t Fit setting picks
  which, and defaults to degrees. The Lock Screen and expanded Dynamic Island always fit both,
  and the compact Dynamic Island shrinks its reading instead. The setting shows on the Global
  and Live Activity appearance pages when the readout shows both.

## Docs site

The web guide is the implementation target for the Zensical site in `website/`. Adding this
document does not apply website changes. Adopt the guide's tinted neutrals, Recursive
display/body/code voices, underlined links and focus treatment rather than keeping the theme's
type scale unchanged.

The consumer stylesheet belongs at `website/docs/stylesheets/brand.css`: expose the foundation
tokens as `--ll-*` properties, then map the theme's `--md-*` variables to them. Use Zensical's
`default` and `slate` colour schemes for appearance overrides, and keep `font = false` in
`website/zensical.toml` when self-hosting Recursive. The organisation's
[reference tokens](https://github.com/lunchbox-labs/.github/blob/main/brand/tokens.css) provide
the shared values. Compasslet has one main product, so its tray may have one compartment or
be omitted, as the web guide permits.

## Making a change

- Track implementation gaps and rollout work in [issues](https://github.com/lunchbox-labs/compasslet/issues),
  starting from the design-document task [#203](https://github.com/lunchbox-labs/compasslet/issues/203).
  Existing deviations are not new design tokens.
- Copy shared token names as well as values into the relevant platform consumer. Keep native
  semantic colours native; do not create matching asset sets for web neutrals.
- Run the relevant platform guide's checks on the changed interface. A shared contrast table
  does not verify translucent materials, pressed states, new pairs or the whole product.
- For iOS changes, use the repository's Screenshots workflow and update
  `AppTests/ScreenshotTests.swift` when screens or states change. Follow the review procedures
  in [AGENTS.md](AGENTS.md), and check accessibility settings and VoiceOver beyond screenshots.

