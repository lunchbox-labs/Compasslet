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
  The single-line reading shortens before scaling, with “Last Updated” and a sample time when
  available. Keep the Lock Screen card within its 160pt height limit.
- Live Activity backgrounds belong to the system. Keep semantic primary and secondary text
  rather than copying web neutrals into the extension. Its compact readings use the system's
  text styles for legibility in the available space.
- The Lock Screen card's 14pt side inset and 2pt reading-to-caption spacing are local compact
  layout exceptions, not extra steps in the app-wide spacing scale.
- `CompassActivity/CompassActivityWidget.swift` caps the Dynamic Island readout at
  `.xxxLarge` because its regions have fixed bounds. Lock Screen and small-card layouts must
  still be checked through the accessibility sizes. Preserve the full spoken reading and
  freshness information when visible text is shortened.
- `App/CarPlay/CarPlayCompassTemplate.swift` leaves template layout, text and backgrounds to
  CarPlay. Resolve custom dial colours and dimensions using the car's traits, not the phone's.
  Keep travel direction distinct from the phone's magnetic heading and from a live reading.
- CarPlay's small card has a fixed size. When the reading and Last Updated can't both fit at
  large text sizes, it shows the reading alone, and a status shrinks to fit rather than grow
  past the card.

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

