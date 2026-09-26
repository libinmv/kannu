# Settings construction rules

How a Settings section is built in Kannu. These rules exist so every tab reads like System
Settings, and so anything informational on screen can be selected and copied. They are enforced,
not advisory: `KannuTests/SettingsLayoutRulesTests.swift` scans the sources under
`Kannu/components/Settings/` and fails on a violation, and `.githooks/pre-commit` runs a fast
subset of the same checks. When a rule here and the test disagree, the test wins — fix this file.

## The one law

**Explanatory text is selectable; control labels never are.** A selectable `Text` inside a
`Toggle`/`Picker`/`Button`/`Stepper`/`Slider`/`Menu` label swallows the click meant for the
control. That is why a row with a description hides the control's own label (kept for
accessibility) and draws the title beside the control instead — and why a caption must never live
inside a control's label. If a control needs a caption, put the text next to the control
(`SettingsRow(title, description:)`, or an adjacent `VStack` with the control's label hidden),
never inside it.

## Which component for what

All in `Kannu/components/Settings/SettingsComponents.swift`. Never rebuild these shapes by hand.

| You are adding | Use |
|---|---|
| A section header | `SettingsSectionHeader("…")` — never a raw `Text` in `header: {}` |
| Text under a group of rows | `SettingsFooter("…")` — never a raw `Text` in `footer: {}` |
| A row: title (+ caption) with a trailing control | `SettingsRow("Title", description: "…") { control }` |
| A row that only says something, with no control | `SettingsNoteRow("Title", description: "…")` |
| A slider row | `SettingsSliderRow` — one width everywhere, selectable readout |
| A stepper row | `SettingsStepperRow` — the value then the stepper, same column |
| Several footer lines under one group | `SettingsFooterStack { … }` |
| A read-only trailing value (path, date, count) | `SettingsValueText(value)` |
| A status line with a ready dot | `SettingsStatusText(text, isReady:)` |
| A red error line under a control | `SettingsErrorText(message)` |
| One or more buttons on a row | `SettingsActionRow` — trailing, never a lone left-hanging button |
| Overflow actions on a row | `SettingsMoreMenu { … }` (the "…" button) |
| Free-standing explanatory text | `.settingsDescriptionStyle()` (selectable, secondary, wraps) |
| A spacing, a width, a dot size | `SettingsMetrics.<token>` — never a number in place |
| A copy-to-pasteboard action for agents | `CopyForAgentButton` |

## The content standard

The components above already imply one set of numbers. `SettingsMetrics` in
`SettingsComponents.swift` is now where those numbers live, and it is the source of truth — this
section describes it, it does not define it.

| Dimension | The rule | Token |
|---|---|---|
| A row's title | The Form's own body type. Never restyled. | — |
| Every secondary line | `settingsDescriptionStyle()` — `.subheadline`, secondary, selectable. Pass `tint:` only when the colour means something (red for a failure, orange for a partial result). | — |
| Title to description | 2 | `labelStack` |
| Inside a row's trailing content | 8 | `rowContent` |
| Between footer lines | 6 | `footerStack` |
| A slider or stepper's whole trailing column | 220 | `sliderWidth` |
| Its readout, trailing, monospaced digits | minWidth 40 | `valueColumn` |
| The ready dot in a status line | 7 | `statusDot` |
| Inside a card | 12 | `cardPadding` |

- **No ad-hoc type in a row.** `.caption`, `.caption2` and `.system(size:)` do not belong on text
  that sits in a Form row's label or control column — that is what made one section's descriptions
  wrap at three different widths. They stay for badges, chips and icon glyphs, and inside a card
  that has its own compact scale; `SettingsLayoutRulesTests` pins how many survive per file.
- **A row adds no padding.** The grouped `Form` pads its rows already, so `.padding(.vertical, …)`
  on a row makes that one row taller than its neighbours. Padding belongs to cards, popovers,
  chips and empty states — nowhere else. Pinned per file.
- **One control size per section.** A Form row uses the default size. `.small` is for controls
  inside a card (`SettingsPermissionCallout`, `SecurityFindingRow`, an extension's expanded
  panel), and then for every control in that card.
- **Every row is a row.** `SettingsRow`, `SettingsActionRow`, `SettingsSliderRow`,
  `SettingsStepperRow`, `SettingsNoteRow` or a raw `LabeledContent` — so the label column and the
  control column line up down the whole section. A bare `VStack` with `frame(maxWidth: .infinity)`
  is not a row: it runs the full width and breaks the grid. Use `SettingsNoteRow` for a line that
  only says something.
- **A slider is never hand-built.** `SettingsSliderRow` is the only shape; a row whose value reads
  in its own title passes `valueText: nil` and the readout column stays reserved, so the bar is
  the same length everywhere. Same for `SettingsStepperRow`.
- **An error line is a sibling of the row it belongs to**, so it takes that row's inset — including
  inside an Advanced disclosure.
- **`SettingsValueText` is for a trailing value, never for a leading line.** It is one line with
  middle truncation, which is right for `/Users/…/snapshot.json` — both ends carry the meaning — and
  wrong for anything that reads as a sentence, which renders with its middle amputated. A full-width
  line under a title takes `.settingsDescriptionStyle()`, which wraps and matches the summary above
  it. An earlier version of this rule said the opposite ("a card's metadata goes in
  `SettingsValueText`"), and `SecurityFindingRow` followed it for four prose lines in 1.3.1; the
  component's own doc comment says trailing, and the component wins.
- **A card's metadata appears only when it says something.** Suppress it when it adds nothing: a row
  standing for a single occurrence, with two identical dates, is noise dressed as information —
  `SecurityFindingRow` omits its recurrence line in exactly that case. And state a fact once. The
  same count in prose *and* as a value reads as two different facts, which is why the sighting
  summaries stopped appending "Seen N times." once the row began showing the real total.

## Section rules

- `SettingsRow`'s control slot is for controls whose own label the row replaces — Toggle, Picker,
  Stepper. It applies `.labelsHidden()` to the whole slot, an environment modifier: a `Menu` or a
  popover-anchoring button placed there loses its label and its items' titles and reads as dead
  (the "Policy rules" "…" bug). Such controls go in a raw `LabeledContent` with a
  `SettingsRowLabel` (the `analysisRow` shape) or a `SettingsActionRow`.

- One concern per `Section`; separate concerns get separate Sections, never a `Divider` inside one.
- A section that mixes everyday controls with rarely-needed ones may tuck the rare rows into one
  `DisclosureGroup` labelled **Advanced** (collapsed by default), keeping the section glanceable.
  Rows inside it carry no highlight ids; their search entries point at the disclosure's own id,
  so search always lands on something visible (the ADR scans section is the model).
- Every row with a `settingsSearchIndex` entry carries a `.settingsHighlight(id:)` whose id
  matches the entry exactly (`SettingsHighlightInventoryTests` pins the pairing and the counts;
  the counts move only as a deliberate edit).
- Captions and footers state what the thing does and what "off" means, in plain words.
- Badges (`customBadge`, `comingSoonTag`, `alphaBadge`, `proFeatureBadge`) are decorative chips
  and stay unselectable — they are the pinned exceptions in `SettingsLayoutRulesTests`, along
  with labels inside tappable cards. A new exception is added to that pin with a reason, not
  slipped past it.
- User-facing strings use `String(localized:)`; the shared components take `LocalizedStringKey`
  so literals localize on their own.

## Selectability in practice

- New informational `Text` styled secondary/caption gets `.textSelection(.enabled)` or goes
  through `settingsDescriptionStyle()`; the layout test counts the survivors per file.
- A container-level `.textSelection(.enabled)` covers every `Text` inside it — fine for a small
  legend or a two-line prose row.
- `LabeledContent` labels and values are display, not controls: both sides may be selectable.
