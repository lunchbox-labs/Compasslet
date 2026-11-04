# Compasslet design

This file sets Compasslet's visual language: colour, type, spacing, shape and motion. It covers the
iPhone app, its Live Activity, CarPlay and the docs site at
[compasslet.lunchbox-labs.dev](https://compasslet.lunchbox-labs.dev/). Brand values come from the
organisation's [colour guidance](https://github.com/lunchbox-labs/.github/blob/main/brand/colors.md).
If the two ever disagree on a brand value, the organisation's guidance wins and this file is
updated to match.

This file describes where the app is going.
[Where the app differs today](#where-the-app-differs-today) lists what still has to change to match
it.

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

Each role has a light and a dark value, and a stronger value for Increase Contrast where it needs
one. The app defines them as colour sets in `App/Assets.xcassets`, named in the last column, so
appearance and contrast changes switch them automatically. The Live Activity extension has no
asset catalog, so the colours it needs are chosen in code from the colour scheme, with the same
values.

| Role | Light | Dark | Increase Contrast | Use | Colour set |
| --- | --- | --- | --- | --- | --- |
| Background | `#FFF8FE` | `#18111A` | — | Screen backgrounds, including the compass | Background |
| Grouped background | `#F7EFF5` | `#18111A` | — | Behind inset grouped lists such as Settings | GroupedBackground |
| Surface | `#FFFFFF` | `#241A26` | — | Grouped list rows, the tour card | Surface |
| Text | `#281423` | `#FFF5FD` | — | Body text, headings, the dial's major ticks | Text |
| Secondary text | `#736470` | `#AEA5AE` | `#5C4D59` / `#C9C0C8` | Explanations, footers, captions, dial labels and minor ticks | SecondaryText |
| Accent | `#992B91` | `#F78AEE` | `#7D2276` / `#FFA9F7` | Links, tinted buttons, toggles, the dial index, the heading arrow | AccentColor |
| Primary action fill | `#F78AEE` | `#F78AEE` | — | The one main button on a screen | PrimaryActionFill |
| Primary action label | `#281423` | `#281423` | — | Text on the primary action fill | PrimaryActionLabel |
| Label on accent | `#FFFFFF` | `#281423` | — | Text on an accent fill, such as Settings Done | ConfirmActionLabel |
| Control border | `#992B91` | `#F78AEE` | as Accent | Edges of pink buttons and fields | AccentColor |
| Separator | `#E1DEE0` | `#473D48` | `#B4A8B1` / `#696169` | Decorative dividers and hairlines | Separator |
| North and error | `#D70015` | `#FF6961` | — | The dial's north marker and "N", error text | North |

Contrast, measured with the WCAG formula against Grouped background, Background and Surface, the
backgrounds each colour can sit on (light, then dark):

| Pair | Light | Dark |
| --- | --- | --- |
| Text | 15.33:1 to 17.29:1 | 15.78:1 to 17.40:1 |
| Secondary text | 4.92:1 to 5.55:1 | 7.03:1 to 7.75:1 |
| Secondary text, Increase Contrast | 7.00:1 to 7.89:1 | 9.48:1 to 10.46:1 |
| Accent | 5.99:1 to 6.75:1 | 7.86:1 to 8.66:1 |
| Accent, Increase Contrast | 7.88:1 to 8.89:1 | 9.81:1 to 10.82:1 |
| Primary action label on fill | 8.09:1 | 8.09:1 |
| Label on accent fill | 6.75:1 | 8.09:1 |
| Control border against the fill | 3.16:1 | — |
| North and error | 4.77:1 to 5.38:1 | 5.95:1 to 6.57:1 |

Notes:

- **Primary action.** Pink fill with the dark label in both appearances, outlined with the control
  border, which shows on light surfaces where the pink alone is only 2.14:1 against white. White on
  the pink is 2.14:1, so the label is never white.
- **North stays red.** A compass reads north as red, so north keeps a red of its own rather than
  the brand pink. These are the system's higher-contrast reds, chosen so the small "N" passes as
  text. Error text uses the same red, always with an icon or words that say what went wrong.
- **Decorative marks.** The dial's rim and the symbol shown when there's no heading are
  decoration. They use the system's tertiary and quaternary styles and don't need to meet a
  contrast ratio. Under Increase Contrast the dial thickens its ticks and strengthens the rim
  rather than promoting decorative marks to Text.
- **Left to the system.** Alerts, sheets, menus, tips, the keyboard and Liquid Glass keep their
  system colours. CarPlay templates keep the system's colours too. The Live Activity's text keeps
  the system's primary and secondary styles, because the system draws the Lock Screen and Dynamic
  Island backgrounds.
- **Dark mode is not pure black.** Backgrounds use the brand's dark plum, not `#000000`.
- **Measure what the system blends.** Glass and tinted fills can be partly transparent. Check the
  rendered colours in captures, not only the values above.

## Type

The app uses San Francisco through Dynamic Type text styles, so every size follows the person's
text size setting. A size tied to a drawing, such as the dial's labels, scales with both the dial
and the text size, and stops at a stated cap.

| Role | Style | Notes |
| --- | --- | --- |
| Navigation title | System inline title | Set with `navigationTitle` |
| App name on the compass | Headline | One line |
| Compass readout | Large Title scale, light | Monospaced digits, sized by the appearance settings |
| Live Activity readout | Large Title, or Title 2 in CarPlay, semibold | One line, shortening before it scales |
| Card title | Title 3, bold | The tour card |
| Body | Body | Default for rows and prose |
| Primary action label | Body, semibold | |
| Supporting detail | Subheadline | Accuracy, coordinates, location notices |
| Explanation | Footnote | Secondary text, under a control or in a card |
| Caption | Caption or Caption 2 | Secondary text in tight places, such as the Live Activity |

- Numbers that change, such as degrees and times, use monospaced digits so they don't jitter.
- Text that must stay on one line first switches to a shorter form, as the Live Activity readout
  does, and only then scales down, to no less than 65%.
- Capitalisation follows the "UI capitalization" rules in [AGENTS.md](AGENTS.md).
- The docs site keeps its theme's type scale and uses the same colour roles for text. Links in
  prose are underlined.

## Spacing

Spacing uses a 4-point scale with a 2-point half step. Pick the nearest step, not an in-between
value.

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

- The Lock Screen Live Activity keeps its 14-point side margin, the one value off the scale.
- Every control's touch target is at least 44 by 44 points, even when it draws smaller.
- Grouped lists keep the system's insets and row heights.
- Insets around text grow with Dynamic Type through `@ScaledMetric`, as the primary action does, so
  large text doesn't crowd its container.

## Shape and depth

- **Cards** use a 20-point continuous corner radius.
- **Buttons** are capsules. Floating controls on the compass, such as the Live Activity button, are
  single Liquid Glass shapes: the glass is the button's only surface, with nothing drawn under it.
- **Nested shapes** keep their corners concentric with their container where the padding allows; a
  capsule inside a card is the exception.
- **No custom shadows.** Depth comes from system materials, Liquid Glass and the tour's scrim. In
  dark mode, where a Surface card barely stands out from the dimmed screen, the card takes a
  1-point Separator edge instead of a shadow.

## Motion

- Use the system's standard transitions and springs, and keep custom timings short.
- With Reduce Motion on, the compass uses the reduced-motion appearance the person chose (a
  text-only reading or a dial with reduced movement), and new transitions prefer fades to movement.
- Values that wrap, such as a direction crossing north, are replaced rather than animated, so
  nothing spins the long way round.

## Components

- **Primary action** (`PrimaryActionButtonStyle`):
  - A capsule with the primary action fill and label, a 1-point control border, at least 50 points
    tall.
  - It darkens with 12% black on press instead of fading, keeping the label at 6.26:1. It dims to
    40% when disabled, which contrast rules exempt.
  - Use one per screen at most.
- **Confirming toolbar button** (Settings Done): the system's prominent glass style, filled with
  the Accent and labelled with Label on accent.
- **Links and text buttons**: Accent. A `Link` needs `.foregroundStyle(.tint)`, because the system
  otherwise draws it in its own blue.
- **Toggles**: tinted with the Accent through `.tint`, because a switch stays system green
  otherwise. The plum track is 5.57:1 against the off track in light mode.
- **Tour card**: Surface, 20-point radius and padding, a card title, body text, a step count in
  Secondary text and the primary action. The spotlight ring is white at 2 points, over the black
  55% scrim.
- **Compass dial**: major ticks in Text, labels and minor ticks in Secondary text, north in North,
  the index marker in Accent, and decorative marks as above. When there's no heading, the dial
  dims and the status text says why.
- **Live Activity**: text only, with no direction arrow. The reading sits on one line, with Last
  Travel in the system's secondary style. The Lock Screen card stays within the 160-point height
  Apple allows.
- **CarPlay**: the system's templates and colours, with the course arrow in Accent.

## Docs site

The site at [compasslet.lunchbox-labs.dev](https://compasslet.lunchbox-labs.dev/) uses the same
colour roles:
- Background for the page.
- Text and Secondary text.
- Accent for links, the header bar and the current-page highlight.

Its stylesheet, `website/docs/stylesheets/brand.css`, maps these roles onto the theme's variables
and owns the site-only details. Focus outlines follow the organisation's guidance: 3 pixels wide
with a 3-pixel offset in Text colour, keeping a gap of the background colour between a pale outline
and a pink button in dark mode.

## Where the app differs today

These are the changes still needed to match this file. Each lands as its own pull request, and
this list shrinks as they merge.

- **Backgrounds, surfaces and text.** The app uses the system's neutral backgrounds, label colours
  and separators. It should use the Background, Grouped background, Surface, Text, Secondary text
  and Separator sets, and the Increase Contrast values above.
- **North.** The dial draws north in the system red, which is 3.55:1 or less on light
  backgrounds.
- **Toggles** are system green.
- **Dial labels** size with the dial but not with Dynamic Type.
- **Tour card** has a drop shadow instead of the dark-mode edge.
- **CarPlay's course arrow** is system teal.
- **Spacing** uses some off-scale values (1, 6 and 10 points).
- **The CarPlay Live Activity's status** can scale to 50%.
- **Dial labels** switch to Text under Increase Contrast rather than to the stronger Secondary
  text.

The docs site follows the same pattern: its colours arrive with
[pull request 202](https://github.com/lunchbox-labs/compasslet/pull/202), and underlined prose
links and the focus outline described above are still to add.

## Changing this file

Add or change a token here first, with its light and dark values and its contrast, then use it in
the app or the site. Check every new colour pair in both appearances. Capture the affected screens
with the Screenshots workflow in light, dark and the largest text size. Check Increase Contrast by
hand, since the workflow doesn't capture it.
