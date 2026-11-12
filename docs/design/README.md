# Progen design system

Flat, quiet, tool-like. A cool-grey base, a dark teal sidebar and phone app bar, one teal brand colour, five accent tones for badges, hairline borders, small radii. Source of truth: `lib/core/design_tokens.dart`, `lib/core/app_colors.dart`, `lib/core/theme.dart`.

## Palette

Hand-picked `ColorScheme` (no seed generation) plus a `ThemeExtension` for semantic colours. Read with `Theme.of(context).colorScheme` or `context.colors`. Never use `Colors.*` in screens.

| Role | Light | Dark |
|---|---|---|
| primary (teal) | `#0B6157` | `#5FC4B1` |
| surface | `#FFFFFF` | dark neutral |
| page background | `#EFF2F4` | `#111413` |
| text (onSurface) | `#1A2124` | light neutral |
| hairline | `#E1E4E8` | `#2C2F2E` |
| sidebar / selected row | `#0A3F39` / `#14574F` | `#0B2A26` / `#14463F` |
| success / warning / danger / info | `#1A6E3F` / `#8A5200` / `#B3261E` / `#1D5A9E` | lightened equivalents |

`Accent` (teal, amber, indigo, rose, sky) gives an icon and tint pair (`context.colors.accent(tone)`) for `IconBadge`, `KpiTile` and `SectionCard` icons. Each semantic colour has a `*Container` and `on*Container` pair for chips and banners. Text and chip pairs were checked against WCAG AA (4.5:1 for text) in both themes. Colour is never the only signal: a status always carries its word.

## Type

IBM Plex Sans (OFL, bundled in `assets/fonts/`, licence in `OFL-IBMPlexSans.txt`), weights 400/500/600/700. Chosen for clear tabular figures, a real rupee sign and a technical, non-default look. Tabular figures are on for every style so columns of money align.

Sizes are one step smaller from 900 px wide (the "compact" desktop theme); phones keep the larger value.

| Style | Desktop / phone |
|---|---|
| headlineSmall (page title) | 18 / 19, 700 |
| titleLarge | 16 / 17, 600 |
| titleMedium (card title) | 14 / 15, 600 |
| bodyLarge / bodyMedium | 14 / 15 and 13 / 14, 400 |
| labelLarge (buttons) | 13 / 14, 500 |
| bodySmall (captions) | 12, muted |
| labelSmall | 11 / 500 |

## Spacing and shape

`Space`: 4, 8, 12, 16, 24, 32, 48. `Radii`: 3, 5, 7. Page gutter 12 on phones, 16 from 900 px. Content max width 1600. Cards are flat with a hairline border, no shadow. From 900 px wide the compact theme gives 36 px buttons and 38 to 42 px table rows. Phones keep 48 px touch targets (`Layout.touchTarget`).

## Forms

- `FormPage` fills the width up to 1600 px and is never narrower than `Layout.formMinMaxWidth` (1200), whatever `maxWidth` a screen passes.
- Fields go in `FormRow`: a grid of 2 to 4 columns (cells 240 to 520 px), one column under 560 px. A lone field in a `FormRow` stays at 520 px, left aligned. Never put a bare `TextFormField` in a wide card.
- Save and Cancel sit in `FormPage.bottomBar` (`FormActionBar`), pinned under the scrolling form. Document screens (`DocFormLayout`) use `DocSaveBar`. The handler and busy state are unchanged by the move.

## Components (`lib/widgets/`)

- `StatusChip(status)`: tone from the status word (`toneForStatus`), label always shown.
- `MoneyText(amount)`: Indian grouping, tabular, negatives in danger colour, `compact` for lakh/crore.
- `KpiTile(label, value, hint, tone)`: one figure, one hint line.
- `SectionCard`, `PageHeader`, `FilterBar`, `Pill` (`layout.dart`).
- `KeyValueList`: label/value pairs for detail screens.
- `ActivityTimeline`: events joined by a hairline, newest first.
- `Skeleton`, `SkeletonList`: loading placeholders. `LoadingView` falls back to a spinner in small slots.
- `EmptyView(message, illustration:, action:)`, `ErrorView`: see below.
- `LogoMark`, `Wordmark`: brand, drawn in code. `Illustration(kind)`: line drawings drawn with `CustomPainter`.

## Icons

One family: Material outlined (`Icons.*_outlined`). No filled or rounded variants, no mixing. Icons accompany a label or tooltip, except universally known ones (close, search). Size 20 in lists and menus, 24 in app bars.

## Voice and tone

Plain, specific, short. Say what happened and what to do next. Sentence case everywhere, including nav groups, buttons and column headers. Use "you" sparingly. No exclamation marks, no filler ("Oops", "Please wait", "Successfully"). Name the object: "Invoice INV-0042 posted", not "Success". Abbreviations only where Indian accounting uses them (GST, TDS, HSN).

## Empty and error patterns

- Empty list: illustration, one sentence saying what belongs here, one primary action if the user can create it. "No invoices yet. Create your first invoice."
- Empty filter result: say the filter matched nothing and offer to clear it.
- No permission: lock icon, "You do not have access to this page", name the permission area.
- Error: what failed in plain words, then Retry. Network: "Cannot reach the server. Check your connection and try again."
- Loading: skeleton rows for lists, spinner for small slots; never a blank screen.

## Responsiveness

Verified from 320 to 1920 px. Under 900 px: drawer navigation, single column, 48 px targets. At 900 px and up: sidebar, breadcrumbs on sub-pages, denser tables, dashboard in a multi-column grid.
