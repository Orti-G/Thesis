---
name: GRID
description: Live whole-house power, the bill it is heading toward, and what to do about it, read from the GRID device.
colors:
  signal-orange: "#F26E22"
  header-orange: "#FA8B39"
  orange-ink: "#C2501A"
  ground: "#FAFAFA"
  card-white: "#FFFFFF"
  hairline: "#ECECEC"
  ink: "#1E1E1E"
  body-ink: "#444444"
  muted-ink: "#5F6368"
  nav-ink: "#8C6B5E"
  pill-ink: "#2B1A10"
  icon-well: "#F1F3F4"
  rise-red: "#E53935"
  fall-green: "#2E7D32"
typography:
  display:
    fontFamily: "Roboto, sans-serif"
    fontSize: "28px"
    fontWeight: 800
    letterSpacing: "-0.5px"
    fontFeature: "tnum"
  headline:
    fontFamily: "Roboto, sans-serif"
    fontSize: "24px"
    fontWeight: 800
    letterSpacing: "-0.5px"
  section:
    fontFamily: "Roboto, sans-serif"
    fontSize: "20px"
    fontWeight: 700
  title:
    fontFamily: "Roboto, sans-serif"
    fontSize: "15.5px"
    fontWeight: 800
    lineHeight: 1.3
  body:
    fontFamily: "Roboto, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Roboto, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  caption:
    fontFamily: "Roboto, sans-serif"
    fontSize: "12px"
    fontWeight: 600
  nav-label:
    fontFamily: "Roboto, sans-serif"
    fontSize: "10px"
    fontWeight: 500
rounded:
  swatch: "3px"
  badge: "10px"
  inset: "12px"
  card: "20px"
  nav-item: "30px"
  nav: "40px"
  pill: "999px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "20px"
  xl: "24px"
components:
  header-field:
    backgroundColor: "{colors.header-orange}"
    textColor: "{colors.card-white}"
    padding: "4px 20px 16px"
  header-tile:
    textColor: "{colors.card-white}"
    rounded: "{rounded.card}"
    padding: "16px"
  header-chip:
    textColor: "{colors.card-white}"
    rounded: "{rounded.pill}"
    height: "48px"
  header-chip-selected:
    backgroundColor: "{colors.card-white}"
    textColor: "{colors.orange-ink}"
    rounded: "{rounded.pill}"
  content-card:
    backgroundColor: "{colors.card-white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "16px"
  state-card:
    backgroundColor: "{colors.card-white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "20px 20px 16px"
  tab:
    textColor: "{colors.muted-ink}"
    typography: "{typography.label}"
    height: "52px"
  tab-selected:
    textColor: "{colors.orange-ink}"
  count-badge:
    backgroundColor: "{colors.orange-ink}"
    textColor: "{colors.card-white}"
    rounded: "{rounded.badge}"
  nav-bar:
    backgroundColor: "{colors.card-white}"
    textColor: "{colors.nav-ink}"
    rounded: "{rounded.nav}"
    height: "72px"
  nav-item-selected:
    backgroundColor: "{colors.signal-orange}"
    textColor: "{colors.card-white}"
    rounded: "{rounded.nav-item}"
    padding: "8px 10px"
  hint-pill:
    backgroundColor: "{colors.card-white}"
    textColor: "{colors.pill-ink}"
    typography: "{typography.caption}"
    rounded: "{rounded.card}"
    padding: "6px 12px 6px 8px"
  bakit-panel:
    textColor: "{colors.body-ink}"
    rounded: "{rounded.inset}"
    padding: "12px"
  text-button:
    textColor: "{colors.orange-ink}"
    height: "48px"
---

# Design System: GRID

## Overview

**Creative North Star: "The Meter Face"**

GRID reads like the face of a household electric meter turned warm: a flat orange field across the top of the screen where the live numbers sit in translucent white tiles and roll digit by digit like meter wheels, and a quiet off-white desk below where cards explain what those numbers mean. The orange field is where the household looks; the desk is where it reads. Dashboard and Advisories are built this way; Billing, Alerts and Settings predate it and carry older variants (see drift notes in the sidecar).

Density is moderate and phone-first: one column, 16 to 20px gutters, a floating white pill nav that the content scrolls under. Depth is mostly flat. The system leans on Material 3 defaults (Roboto, stock TabBar, FilterChip, buttons and ripples) re-coloured per screen with raw hex fields; there is no custom ThemeData and no dark theme. Charts are custom-painted directly onto the orange field and respond to touch: hold or tap a point and the header tiles re-read for it, with a selection haptic per step; release returns to the live state.

Motion is functional and always optional: bars rise once, digits roll, labels swap, and every animation collapses to zero under the system's Remove animations setting.

**Key Characteristics:**
- Flat orange header field with white type and translucent white glass tiles.
- Off-white ground with white cards edged by a single hairline rule at 20px radius.
- Numbers that change roll per digit with tabular figures.
- Painted, touch-scrubbable charts living inside the header, not in cards.
- Roboto at heavy Material weights (700 to 900) for every number and title.
- A floating, blurred white pill as the only navigation chrome.

## Colors

One warm orange family carries the identity against cool, near-neutral greys; red and green appear only as data direction.

### Primary
- **Signal Orange** (signal-orange): fills and marks on white: the selected nav pill, tab indicator, tab ripple tint, progress spinners, hint-pill icon. Not used for text on white.
- **Header Orange** (header-orange): the flat header field behind white type, tiles and painted charts; also the status-bar band so the field runs to the top edge.
- **Orange Ink** (orange-ink): orange that has to be read on white: selected tab label, count badge, "Bakit?" toggle, Try again buttons, the label of the selected header chip, advisory category icons.

### Neutral
- **Ground** (ground): the scaffold background below the header.
- **Card White** (card-white): cards, the nav pill (at 80% over blur), hint pills, the selected header chip; and every piece of type on the orange field.
- **Hairline** (hairline): the 1px rule around content cards and under the pinned tabs.
- **Ink** (ink): titles and headings on white.
- **Body Ink** (body-ink): advisory and card body copy.
- **Muted Ink** (muted-ink): unselected tabs, state-card icons, flat (unchanged) rate figures.
- **Nav Ink** (nav-ink): unselected nav icons and labels, a warm brown-grey that ties the pill to the orange.
- **Pill Ink** (pill-ink): dark warm text inside white pills that float over the orange field (scrub hints, chart chips).
- **Icon Well** (icon-well): the circular backing behind neutral state-card icons.

### Data direction
- **Rise Red** (rise-red): usage or rates going up, bracket advisories, the Alerts nav badge.
- **Fall Green** (fall-green): usage or rates going down.

### Named Rules
**The Ink Swap Rule.** Orange that is read as text on white is Orange Ink, never Signal Orange. Signal Orange is for fills, indicators and icons on white; Header Orange is for the field.

**The White On Field Rule.** Everything on the header field is white or translucent white (tiles at 30% to 8% white, borders at 40%, unselected chips at 18%, last-week bars at 38%). No second hue enters the field except data colour inside white pills.

**The Raw Hex Rule.** Colours are declared as `final Color` fields at the top of each screen state using the names above (primaryOrange, topCardColor, bgColor, textDark, orangeInk, hairline). New screens copy these fields verbatim rather than inventing neighbours.

## Typography

**Display Font:** Roboto (Android system default; no fontFamily is set anywhere)
**Body Font:** Roboto

**Character:** One family carried entirely by weight. Numbers and titles sit at 800, labels at 600, body at regular, so hierarchy reads at arm's length on a budget phone without a second face.

### Hierarchy
- **Display** (800, 26 to 28px, -0.5 tracking, tabular figures): live values in header tiles, rolled by RollingNumber. Advisories uses 26px in its two-up tiles; Dashboard uses 28px.
- **Headline** (800, 24px, -0.5 tracking): the screen title or household nickname at the top of the header field.
- **Section** (700, 20px): section headings on the white desk.
- **Title** (800, 15.5 to 16px, 1.3 line height): card and state-card titles.
- **Body** (400, 14px, 1.45 line height): card body copy, Bakit explanations (13px). Must tolerate longer Tagalog strings; no fixed heights on text.
- **Label** (600, 13px): tile labels, units beside values, chip labels (700), tab labels (14.5px, 700 selected and 600 unselected).
- **Caption** (600, 12px): day labels under charts (weight steps to 800 when scrubbed and 900 for today), legends, timestamps, hint pills.
- **Nav label** (10px, 500 unselected, 700 selected): bottom nav only, scaled down rather than wrapped at large font sizes.

### Named Rules
**The Weight Not Face Rule.** Hierarchy comes from Roboto's weights and size, never from a second family, uppercase tracking or decorative styling.

**The Scale With The System Rule.** Type follows the system font-size setting. Long labels shrink (FittedBox scale-down) or ellipsize; they do not clip.

## Layout

Single column. The header field runs full bleed from the status bar down, with 20px horizontal padding; content below sits in a 16px gutter (Advisories) or 20px (Dashboard, Alerts). Cards stack with 12px between them; the two header tiles sit side by side with a 12px gap. Spacing steps are 4, 8, 12, 16, 20 and 24px.

On scrolling screens with more than one job, the header scrolls away and Material tabs pin directly under the status-bar band (52px tabs, hairline rule beneath). Every scrolling screen reserves about 120px of bottom space so the last card clears the floating nav, which floats 28px above the bottom edge with 12px side insets.

## Elevation & Depth

Flat by default. Depth comes from the tonal step between the orange field, the off-white ground and white cards, plus translucent white on orange. Shadows appear only on things that float above content.

### Shadow Vocabulary
- **Nav float** (black 10%, blur 24, y 6): the bottom nav pill.
- **Hint float** (black 12%, blur 10, y 3): white hint pills over the header chart.

### Named Rules
**The Float Earns Shadow Rule.** Only floating overlays cast a shadow. Cards resting on the ground are edged by a hairline rule, not lifted.

**The Blur Must See Something Rule.** Backdrop blur is used where content actually moves behind the surface (the nav pill, blur 8). Over the flat orange field a blur shows nothing and costs a full pass on budget phones, so header tiles are translucent gradients without blur.

## Shapes

Soft and consistent: 20px is the house radius for cards, tiles and hint pills; stadium shapes for chips and buttons; 40px for the nav pill and 30px for its selected item; 12px for inset panels such as the Bakit explanation; 10px count badges; 3px legend swatches. Category icons sit in 32px circles tinted at 12% of their colour; state icons in 40px Icon Well circles.

## Components

### Header Field and Glass Tiles
The signature surface. Flat Header Orange, white headline left and a control right, then a pair of glass tiles: a top-left to bottom-right gradient of white at 30% to 8%, a 1px white border at 40%, 20px radius, 16px padding. Tile label (13px, 600) above a rolling display value with its unit at 13px. During a scrub the label swaps (SwapText, 180ms) to name the selected point.

### Header Chip
Material FilterChip themed for the field: unselected is white at 18% with a 55% white border, white label and a plus icon; selected is solid white with an Orange Ink label and check. Stadium shape, no elevation, 48dp tap target.

### Painted Header Chart
Custom-painted on the field: current values in solid white, comparison values in white at 38%, a partial period hatched. Hold (160ms long press) or tap to scrub; each new point fires a selection haptic and lights its column, the tiles re-read, release (or 1.8s after a tap) returns. A first-run white hint pill explains the gesture once and is then remembered.

### Cards / Containers
- **Corner Style:** 20px.
- **Background:** Card White on Ground.
- **Shadow Strategy:** none; see Elevation.
- **Border:** 1px Hairline.
- **Internal Padding:** 16px (advisory cards, 6px bottom to make room for Bakit), 20px for state cards.

### State Cards
Every data source has loading, empty, offline and error states. Loading is a small 2px Signal Orange spinner centred in 40px of space; the others are a state card: Icon Well circle with a Muted Ink icon, a 16px/800 title, a 14px body, and a Try again text button in Orange Ink when retry is possible.

### Tabs
Stock Material TabBar pinned under the header: 14.5px labels, Orange Ink selected and Muted Ink unselected, a 3px Signal Orange indicator sized to the label with rounded top corners, no Material divider (the hairline rule replaces it), and a Signal Orange 8% ripple. Counts ride in an Orange Ink badge with white 11.5px/800 numerals.

### Buttons
Material buttons, re-coloured. On white: TextButton in Orange Ink, 14px/800, 48dp minimum. On the field: OutlinedButton with white text and a white border, stadium shape.

### Navigation
A floating white pill (72px tall, 40px radius, white at 80% over an 8px blur, Nav float shadow). Five items, 20px Material rounded/outlined icons with 10px labels in Nav Ink; the selected item gets a Signal Orange 30px-radius pill behind a white icon and a black-87% bold label, animated over 200ms. An 8px Rise Red dot marks a live anomaly on Alerts.

### Bakit? Expander
The shared "why" toggle under any backend-generated card: "Bakit?" at 13px/700 plus a rotating chevron in the passed accent (Orange Ink on white), 48dp tall; opens a 12px-radius panel tinted at 7% of the accent with 13px/1.45 explanation text, over 220ms.

### Rolling Number
The shared RollingNumber: each changed digit rolls into place like a meter wheel (420ms, ease-out cubic) with tabular figures so nothing shifts sideways; screen readers get the plain value. Its partner SwapText cross-swaps labels. Both go instant under Remove animations.

## Do's and Don'ts

### Do:
- **Do** start a screen from the header field: flat Header Orange (#FA8B39) to the status bar, white headline at 24px/800, glass tiles at 20px radius.
- **Do** put orange text on white in Orange Ink (#C2501A) and keep Signal Orange (#F26E22) for fills, indicators and icons.
- **Do** edge resting cards with a 1px Hairline (#ECECEC) at 20px radius on the Ground (#FAFAFA).
- **Do** use RollingNumber for any value that updates live or on scrub, and SwapText for the label above it.
- **Do** make header charts scrubbable with a selection haptic per step and a return on release.
- **Do** read `MediaQuery.disableAnimationsOf` and collapse every duration to zero when it is set.
- **Do** give every data source a loading, empty, offline and error state using the state card.
- **Do** keep tap targets at 48dp and let text scale with the system setting.

### Don't:
- **Don't** set Signal Orange (#F26E22) as text on white; at about 2.9:1 it fails body contrast.
- **Don't** lift resting cards with shadows; shadows belong to the nav pill and hint pills only.
- **Don't** add backdrop blur over the flat orange field.
- **Don't** introduce a second typeface, uppercase tracked eyebrows or caption kickers above sections.
- **Don't** invent new neutrals; reuse Ink, Body Ink, Muted Ink and Ground rather than near-duplicates.
- **Don't** colour data in red or green unless it is a direction (rise or fall).
