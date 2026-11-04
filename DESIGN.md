# Compasslet design

This file sets Compasslet's visual language: colour, type, spacing, shape and motion. It covers the
iPhone app, its Live Activity, and the docs site at
[compasslet.lunchbox-labs.dev](https://compasslet.lunchbox-labs.dev/). Brand values come from the
organisation's [colour guidance](https://github.com/lunchbox-labs/.github/blob/main/brand/colors.md).
If the two ever disagree on a brand value, the organisation's guidance wins and this file is
updated to match.

## Principles

- **Native first.** Compasslet looks and behaves like an iPhone app. Use system components,
  navigation and materials, and bring the brand in through colour, not custom chrome.
- **Pink for accents and the main action.** The primary pink `#F78AEE` marks the brand and the
  one main action on a screen. It is not used for small text on light backgrounds, and it is not a
  status colour.
- **Readable at every setting.** Text is 4.5:1 or better against its background in both
  appearances, and meaningful control edges and state indicators are 3:1 or better. Every text
  style follows Dynamic Type, and layouts wrap or stack instead of truncating.
- **Colour is never the only cue.** Pair it with a label, an icon or a shape.
- **Respect the person's settings.** Dark mode, Increase Contrast, Reduce Motion, Reduce
  Transparency and Bold Text all keep working.

## Colour

Each role has a light and a dark value. Ratios are WCAG contrast against the backgrounds named.
The app defines these as colour sets in `App/Assets.xcassets`, so light and dark switch with the
system. The Live Activity extension has no asset catalog, so the colours it needs are defined in
code with the same values.

| Role | Light | Dark | Use | Contrast |
| --- | --- | --- | --- | --- |
| Background | `#FFF8FE` | `#18111A` | Screen backgrounds, including the compass | — |
| Grouped background | `#F7EFF5` | `#18111A` | Behind inset grouped lists such as Settings | — |
| Surface | `#FFFFFF` | `#241A26` | Grouped list rows, the tour card | — |
| Text | `#281423` | `#FFF5FD` | Body text, headings, the dial's major ticks | 15.3:1 or better |
| Secondary text | `#736470` | `#A39AA2` | Explanations, footers, captions, minor ticks | 4.9:1 or better |
| Accent | `#992B91` | `#F78AEE` | Links, tinted buttons, toggles, selection, the dial index | 5.9:1 or better |
| Primary action fill | `#F78AEE` | `#F78AEE` | The one main button on a screen | — |
| Primary action label | `#281423` | `#281423` | Text on the primary action fill | 8.09:1 |
| Label on accent | `#FFFFFF` | `#281423` | Text on an accent fill, such as Settings Done | 6.75:1 and 8.09:1 |
| Control border | `#992B91` | `#F78AEE` | Edges of pink buttons and fields on light surfaces | 3.16:1 with the fill |
| Separator | `#E1DEE0` | `#473D48` | Decorative dividers only | — |
| North | `#D70015` | `#FF6961` | The dial's north needle and "N" | 4.77:1 or better |

Contrast is measured against Background, Grouped background and Surface, whichever the colour can
sit on. Accent text measures 5.99:1 on the light grouped background, 6.47:1 on the light
background and 6.75:1 on white; in dark mode it is 7.86:1 or better.

Notes:

- **Primary action.** Pink fill with the dark label in both appearances, outlined with the control
  border on light surfaces, where the pink alone is only 2.14:1 against white. White on the pink is
  2.14:1, so the label is never white.
- **North stays red.** A compass reads north as red, so north keeps a red of its own rather than
  the brand pink. These are the system's higher-contrast reds, chosen so the small "N" passes as
  text.
- **Increase Contrast.** Secondary text switches to Text, as the dial's labels already do.
- **Left to the system.** Alerts, sheets, menus, the keyboard and Liquid Glass keep their system
  colours. The Live Activity's text keeps the system's primary and secondary styles, because the
  system draws the Lock Screen and Dynamic Island backgrounds; only its direction arrow takes the
  accent. The tour's scrim stays black at 55%.
- **Dark mode is not pure black.** Backgrounds use the brand's dark plum, not `#000000`.

## Type

The app uses San Francisco through Dynamic Type text styles, so every size follows the person's
text size setting. Fixed point sizes are allowed only where a size is tied to a drawing, such as
the dial's labels and readout, and those still scale and stop at a stated cap.

| Role | Style | Notes |
| --- | --- | --- |
| Navigation title | System inline title | Set with `navigationTitle` |
| App name on the compass | Headline | One line, may scale to 65% at the largest sizes |
| Readout | Scaled to the dial, semibold | Monospaced digits, capped by the appearance settings |
| Card title | Title 3, bold | The tour card |
| Body | Body | Default for rows and prose |
| Primary action label | Body, semibold | |
| Explanation | Footnote | Secondary text, under a control or in a card |
| Caption | Caption or Caption 2 | Secondary text in tight places, such as the Live Activity |

- Numbers that change, such as degrees and times, use monospaced digits so they don't jitter.
- Text that must stay on one line may scale down, but no further than 65%. Prefer a shorter form
  of the text first, as the Live Activity readout does.
- Capitalisation follows the UI capitalisation rules in [AGENTS.md](AGENTS.md).
- The docs site keeps its theme's type scale and uses the same colour roles for text.

## Spacing

Spacing uses a 4-point scale. Pick the nearest step, not an in-between value.

| Step | Use |
| --- | --- |
| 2 | Lines that read as one unit, such as the Live Activity's reading and its caption |
| 4 | An icon and its label, tight inline groups |
| 8 | Related items in a stack or row |
| 12 | Text blocks inside a card |
| 16 | Groups inside a card or screen; screen edge margin for overlays and cards |
| 20 | Card padding |
| 24 | Sections of a screen; the compass screen's side margin |
| 32 | Separating major regions of a screen |

- Every control's touch target is at least 44 by 44 points, even when it draws smaller.
- Grouped lists keep the system's insets and row heights.
- Insets that sit around text grow with Dynamic Type through `@ScaledMetric`, as the primary
  action does, so large text doesn't crowd its container.

## Shape and depth

- **Cards** use a 20-point continuous corner radius.
- **Buttons** are capsules. Floating controls, such as the Live Activity button and Settings,
  are single Liquid Glass shapes: the glass is the button's only surface, with nothing drawn under
  it.
- **Nested shapes** keep their corners concentric with their container.
- **No custom shadows.** Depth comes from system materials and Liquid Glass.

## Motion

- Use the system's standard transitions and springs.
- With Reduce Motion on, the compass uses the reduced-motion appearance the person chose (a
  text-only reading or a dial with reduced movement), and new transitions prefer fades to movement.
- Values that wrap, such as a direction crossing north, are replaced rather than animated, so
  nothing spins the long way round.

## Components

- **Primary action** (`PrimaryActionButtonStyle`): a capsule with the primary action fill and
  label, a 1-point control border, at least 50 points tall. It darkens on press instead of fading,
  and dims when disabled. Use one per screen at most.
- **Confirming toolbar button** (Settings Done): the system's prominent glass style, filled with
  the Accent and labelled with Label on accent.
- **Links and text buttons**: Accent. A `Link` needs `.foregroundStyle(.tint)`, because the
  system otherwise draws it in its own blue.
- **Toggles**: tinted with the Accent.
- **Tour card**: Surface, 20-point radius and padding, with a card title, body text, a step count
  in Secondary text and the primary action.
- **Compass dial**: major ticks in Text, minor ticks and labels in Secondary text, north in North,
  and the index marker in Accent.
- **Live Activity**: the reading on one line with the travel arrow in Accent, and Last Travel in
  the system's secondary style. The Lock Screen card stays within the 160-point height Apple
  allows.

## Docs site

The site at [compasslet.lunchbox-labs.dev](https://compasslet.lunchbox-labs.dev/) uses the same
colour roles: Background for the page, Surface for raised areas, Text and Secondary text, and the
Accent for links, the current-page highlight and focus. Its stylesheet,
`website/docs/stylesheets/brand.css`, maps these roles onto the theme's variables. Focus outlines
follow the organisation's guidance: 3 pixels wide with a 3-pixel offset, in Text colour.

## Changing this file

Add or change a token here first, with its light and dark values and its contrast, then use it in
the app or the site. Check every new colour pair in both appearances, and capture the affected
screens with the Screenshots workflow in light, dark and the largest text size.
