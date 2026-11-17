# Everything `std/ui` can draw

The whole interface a generated program may use, as the compiler accepts it and the renderer draws it.

Generated from `entry/src/main/ets/vera/VeraUiCatalog.ets` -- the same table that produces the compiler's
module interface, the validator's rules and the catalogue section of the model's prompt, so nothing here can
drift from what the phone runs. Anything not in this file is not in the language: the compiler rejects it.

53 components, 52 of them with a style set, 9 that hand a value back to a handler, 16 icons, 8 composition rules.

A program picks a component and one style name from a closed set. It cannot set a colour, a padding or a
size: those come from `VeraTheme.ets` and the renderer.

## Every function at a glance

| function | group | what it does |
|---|---|---|
| `ui.Column` | Layout | Vertical stack |
| `ui.Row` | Layout | Horizontal stack |
| `ui.Card` | Layout | Framed group |
| `ui.Scroll` | Layout | Scrolling group |
| `ui.Grid` | Layout | Lays its children out in N equal columns, wrapping onto new rows |
| `ui.Canvas` | Layout | One drawing: the ui.Path children share a single 0..100 field and overlap |
| `ui.Surface` | Drawing | A box the program draws itself every frame with std/gfx shapes |
| `ui.Spacer` | Layout | Vertical gap |
| `ui.Divider` | Layout | A horizontal rule |
| `ui.Text` | Content | A line of text |
| `ui.IntText` | Content | A whole number as text: prefix, the number padded to minimumDigits, suffix |
| `ui.ClockText` | Content | A time of day from minutes since midnight, written as HH:MM |
| `ui.Image` | Content | An https image |
| `ui.Path` | Content | Vector shape |
| `ui.Icon` | Content | One icon on its own |
| `ui.Badge` | Content | A short status, drawn as a chip rather than a line of text |
| `ui.Progress` | Content | A progress bar |
| `ui.Button` | Input | Tappable button |
| `ui.IconButton` | Input | A button that is only an icon |
| `ui.Cell` | Input | Tappable grid cell |
| `ui.ActionBar` | Input | The row of buttons for a screen or a section |
| `ui.TextField` | Input | Text the user types |
| `ui.IntField` | Input | A number the user sets with - and + |
| `ui.TimeField` | Input | A time of day, as minutes since midnight |
| `ui.DateField` | Input | A calendar date, as a local day number |
| `ui.Toggle` | Input | On/off switch |
| `ui.Checkbox` | Input | Tick box |
| `ui.Slider` | Input | Pick a number in a range |
| `ui.Select` | Input | Choose one option |
| `ui.Ticker` | Input | Draws nothing |
| `ui.AppTheme` | Composition | The whole app in one look |
| `ui.Hero` | Composition | A focal area with an optional eyebrow, display title, supporting text, and child content |
| `ui.AdaptiveColumns` | Composition | Ordered content in one or two columns according to available width |
| `ui.Header` | Composition | The app's own title block: eyebrow above, title, supporting line below |
| `ui.Section` | Composition | One part of the screen, with a role: hero summary content supporting warning |
| `ui.SectionHeader` | Composition | A heading inside a section: title, subtitle, and a count on the right |
| `ui.ListGroup` | Composition | One bounded surface holding related ui.ListItem rows, separated for you |
| `ui.ListItem` | Composition | One row of a list: title, subtitle, trailing text, leading icon, tappable |
| `ui.IntListItem` | Composition | A ui.ListItem whose trailing value is a number, formatted for you |
| `ui.Timeline` | Composition | Events in the order they happen, joined by a rail |
| `ui.TimelineItem` | Composition | One moment on a timeline |
| `ui.MetricGroup` | Composition | Two to four ui.Stat or ui.IntStat children across one surface, in equal columns |
| `ui.Stat` | Composition | One number told properly: label above, value large, supporting line below |
| `ui.IntStat` | Composition | A ui.Stat for a number the program holds as an int |
| `ui.KeyValueGroup` | Composition | ui.KeyValueItem children in equal columns, for facts rather than figures |
| `ui.KeyValueItem` | Composition | One labelled fact: label above, value below |
| `ui.InsetBanner` | Composition | A standing status or guidance note in a tone, with one optional action |
| `ui.EmptyState` | Composition | What to show where a collection is empty: title, message, one way forward |
| `ui.Table` | Table | Rows and columns of text, with an optional header row |
| `ui.TableRow` | Table | One row of a ui.Table: one string per column, in order |
| `ui.Skeleton` | Feedback | A placeholder box the size of the content that has not arrived yet |
| `ui.Spinner` | Feedback | A small spinning indicator that something is in progress |
| `ui.Snackbar` | Feedback | A one-line status strip the program raised itself, with one optional action |
| `ui.Sparkline` | Chart | A small line chart from a series of whole numbers |
| `ui.Screen` | Navigation | Identifies the active native screen subtree; all screens share one module and state |
| `ui.BackHandler` | Navigation | Draws nothing; calls the handler on the system back gesture |
| `ui.When` | — | Draws the child when the condition is true, nothing when it is false |
| `ui.intToString` | — | A whole number as text |
| `ui.numberToString` | — | A fractional number as text |
| `ui.booleanToString` | — | A boolean as text |

The signature of each, with its types, styles and the rule for when to use it, follows below.

## The types

Six types appear in the component signatures, and every one of them is checked at compile time. A seventh,
`number`, reaches `std/ui` only through `ui.numberToString`.

| type | what it is |
|---|---|
| `View` | what every `ui.*` call returns. A program can pass it and store it in an array, and nothing else: there is no way to read a view back, change it or ask it anything. |
| `View[]` | the children of a container, written as an array literal or built with the array functions. 16 properties take one. |
| `string` | text. Also the type of a `style`, an `icon` and an `action`, each with its own rule below. |
| `int` | a whole number. Sizes, counts, minutes, slider values and the `value` a tap carries are all ints. |
| `boolean` | `enabled`, `checked`, `running`. |
| `string[]` | the `options` of `ui.Select`, the `headers` of `ui.Table`, the `cells` of `ui.TableRow`. |
| `number` | a fractional number. No component takes one: `ui.numberToString` is the only place it appears, and every component that holds a figure holds an `int`. |

Three of the string-typed properties are not free text:

- **`style`** is the first argument of every component and comes from that component's own closed set,
  listed under each entry below. A name outside the set, literal or computed, is not an error: the node is
  drawn in the set's `default` style (`body` for text, else the set's first entry) -- see `resolveStyle`.
- **`icon`** is one of the 16 names below, or `""` for none. An unknown literal is `E2108`.
- **`action`** is the name of a handler function in the program. A name with no handler behind it is `E2106`,
  and so is a handler whose parameter type does not match what the component hands it.

A trailing property in `[brackets]` may be left off the call. Only trailing properties are optional, and they
exist so the vocabulary can grow: a program written against an older catalogue still compiles, and a model
that learnt the old signature is not failed for it.

**What a handler looks like.** A component with an `action` calls a function of two arguments -- the state and
the value the component hands over:

```
function onVolume(state: AppState, value: int): AppState { ... }   // ui.Slider, ui.IntField, ui.TimeField, ui.Select, ui.Ticker
function onName(state: AppState, value: string): AppState { ... }  // ui.TextField
function onMute(state: AppState, value: boolean): AppState { ... }  // ui.Toggle, ui.Checkbox
function onTap(state: AppState, value: int): AppState { ... }      // everything else: the value written into the call
```

A component that takes an `action` but declares no payload of its own -- `ui.Button`, `ui.Cell`, `ui.ListItem`
and the rest -- hands the handler the `value` written into the call, as an int. The handler returns the new
state, and the state is saved for you.

## Layout

*boxes, gaps and rules*

### `ui.Column(style: string, children: View[]): View`

Vertical stack.

**Styles:** `default` `compact` `spacious` `center` `end` `surface` `accent`

### `ui.Row(style: string, children: View[]): View`

Horizontal stack.

**Styles:** `default` `compact` `spacious` `center` `end` `split` `joined` `surface` `accent`

### `ui.Card(style: string, children: View[]): View`

Framed group.

**Styles:** `surface` `accent` `success` `warning` `danger`

### `ui.Scroll(style: string, children: View[]): View`

Scrolling group.

### `ui.Grid(style: string, columns: int, children: View[]): View`

Lays its children out in N equal columns, wrapping onto new rows.

**Styles:** `default` `compact` `spacious`

### `ui.Canvas(style: string, children: View[]): View`

One drawing: the ui.Path children share a single 0..100 field and overlap.

**Styles:** `default` `small` `large`

### `ui.Spacer(style: string): View`

Vertical gap.

**Styles:** `none` `small` `default` `large`

### `ui.Divider(style: string): View`

A horizontal rule.

## Content

*what the program shows*

### `ui.Text(style: string, text: string): View`

A line of text.

**Styles:** `display` `title` `heading` `body` `caption` `eyebrow` `metric` `muted` `success` `warning` `danger`

### `ui.IntText(style: string, value: int, prefix: string, suffix: string, minimumDigits: int): View`

A whole number as text: prefix, the number padded to minimumDigits, suffix.

**Styles:** `display` `title` `heading` `body` `caption` `metric` `muted` `success` `warning` `danger`

> Use instead of ui.Text with ui.intToString. minimumDigits 2 writes 7 as "07", so a clock is ui.IntText("body", h, "", ":", 2) beside ui.IntText("body", m, "", "", 2) and needs no pad function. Use prefix and suffix for units and currency rather than gluing strings together.

### `ui.ClockText(style: string, minutes: int, prefix: string, suffix: string): View`

A time of day from minutes since midnight, written as HH:MM.

> The only way to show a time. Never build one from two ui.IntText and never write a padding function for it: 9:05 in the morning is ui.ClockText("body", 545, "", ""). Minutes since midnight is what time.hourOfDay() * 60 + time.minuteOfHour() gives and what ui.TimeField hands back, so the three fit together.

### `ui.Image(style: string, src: string, alt: string): View`

Https image.

### `ui.Path(style: string, commands: string, spinPeriodMs: int): View`

Vector shape; spinPeriodMs > 0 rotates it.

**Styles:** `default` `accent` `success` `warning` `danger` `muted` `light`

### `ui.Icon(style: string, [name: string]): View`

One icon on its own.

**Styles:** `default` `muted` `accent` `success` `warning` `danger`

> For an icon that is not part of something else. Most icons should instead be the icon property of a ListItem, Banner, EmptyState, Header or Stat, which places them properly.

### `ui.Badge(style: string, text: string, [icon: string]): View`

A short status, drawn as a chip rather than a line of text.

**Styles:** `default` `accent` `success` `warning` `danger`

> For the state of the thing next to it -- "Reached", "Overdue", "3 left". Pass icon "" for no icon. Do not use it for ordinary text.

### `ui.Progress(style: string, label: string, value: int, maximum: int): View`

A progress bar.

**Styles:** `default` `accent` `success` `warning` `danger`

## Actions and input

*everything a person can touch*

### `ui.Button(style: string, text: string, action: string, value: int, enabled: boolean): View`

Tappable button.

**Styles:** `primary` `secondary` `success` `danger`

### `ui.IconButton(style: string, [icon: string], label: string, action: string, value: int, enabled: boolean): View`

A button that is only an icon; label is what it does, for accessibility.

**Styles:** `primary` `secondary` `success` `danger` `quiet`

> Use for a secondary action beside a primary one, so a row of three actions does not become three blocks of text. The label is never drawn but must still say what the button does. Keep the one action a person is most likely to want as a full ui.Button.

### `ui.Cell(style: string, text: string, action: string, value: int, enabled: boolean): View`

Tappable grid cell.

**Styles:** `default` `accent` `success` `danger`

### `ui.ActionBar(style: string, children: View[]): View`

The row of buttons for a screen or a section.

**Styles:** `default` `end` `center` `spread`

> Gather the actions into one of these instead of leaving buttons loose in a Column. It takes ui.Button, ui.IconButton and ui.Badge. One action is primary and the rest are not.

### `ui.TextField(style: string, label: string, value: string, action: string, [keyboardType: string], [required: boolean], [requiredMessage: string], [minLength: int], [minLengthMessage: string], [maxLength: int], [maxLengthMessage: string], [pattern: string], [patternMessage: string], [email: boolean], [emailMessage: string]): View`

Text the user types; the handler takes (state, value: string).

**Styles:** `default` `multiline`

**Handler receives:** `string`

> `keyboardType` is `""`, `"number"`, `"phone"` or `"email"` and only changes which keys the on-screen keyboard offers — it never rejects a character. `required`, `minLength`, `maxLength`, `pattern` (a regex) and `email` each turn on one check, shown under the field in its own words via the matching `...Message` prop (a sensible default is used if left blank). None of them stop what reaches the handler — VERA has no way to refuse a value once typed, so these are guidance shown to the person, not enforcement.

### `ui.IntField(style: string, label: string, value: int, minimum: int, maximum: int, action: string): View`

A number the user sets with - and +; the handler takes (state, value: int).

**Handler receives:** `int`

> The only way to get a number from the person. A ui.TextField hands you a string and there is no way to turn a string into an int, so a typed quantity has to come through here. minimum and maximum bound it.

### `ui.TimeField(style: string, label: string, value: int, action: string): View`

A time of day, as minutes since midnight; the handler takes (state, value: int).

**Handler receives:** `int`

> For a time the person chooses. The value is minutes since midnight, which is the same shape time.hourOfDay() * 60 + time.minuteOfHour() produces, so it compares with the clock directly.

### `ui.DateField(style: string, label: string, value: number, action: string): View`

A calendar date, as a local day number; the handler takes (state, value: number).

**Handler receives:** `number`

> For a date the person chooses -- a due date, a birthday, a trip. The value is the day number time.daysSinceEpoch() returns, so start it at today with time.daysSinceEpoch(), compare it with today directly, and subtract two of them for a count of days. ui.dateToString(day) writes it as "30 Oct 2026" inside another component's text; (day + 4) % 7 is its weekday, 0=Sunday, as time.weekday() counts. Pair it with ui.TimeField for a date and a time.

### `ui.Toggle(style: string, label: string, checked: boolean, action: string): View`

On/off switch; the handler takes (state, value: boolean).

**Handler receives:** `boolean`

### `ui.Checkbox(style: string, label: string, checked: boolean, action: string): View`

Tick box; the handler takes (state, value: boolean).

**Handler receives:** `boolean`

### `ui.Slider(style: string, label: string, value: int, minimum: int, maximum: int, action: string): View`

Pick a number in a range; the handler takes (state, value: int).

**Handler receives:** `int`

### `ui.Select(style: string, label: string, options: string[], selected: int, action: string): View`

Choose one option; the handler takes (state, index: int).

**Handler receives:** `int`

### `ui.Ticker(style: string, id: string, intervalMs: int, running: boolean, action: string): View`

Draws nothing; calls the handler every intervalMs with the elapsed ms.

**Handler receives:** `int`

## Composition

*the shape of an app, not its pixels*

### `ui.AppTheme(style: string, primary: string, children: View[]): View`

The whole app in one look; primary is a "#rrggbb" seed or "" for the preset's own.

**Styles:** `clean` `soft` `expressive` `editorial` `technical` `playful`

> Wrap everything view returns in exactly one of these. The preset is the app's character, so choose it for the app you were asked for: clean for restrained and neutral, soft for calm and friendly, expressive for bold and atmospheric, editorial for content that leads, technical for dense precise numbers, playful for energetic. Do not pick clean just because an example uses it.

### `ui.Hero(style: string, eyebrow: string, title: string, supporting: string, children: View[]): View`

A focal area with an optional eyebrow, display title, supporting text, and related content.

**Styles:** `plain` `accent`

Use `plain` for an open focal area or `accent` for a theme accent surface.
Empty strings omit text. Children can hold a result, visual, or action.
Do not add a redundant Header above Hero. Chat widgets omit Hero.

### `ui.AdaptiveColumns(style: string, minimumWidth: int, children: View[]): View`

Ordered content in one or two equal columns, aligned at the top.

**Styles:** `default` `compact` `spacious`

The renderer measures the container's available width and subtracts the theme gap before it calculates column widths.
It uses one column before measurement and when two columns do not fit.
A nonpositive `minimumWidth` uses 240 vp. A smaller positive value is clamped to 160 vp.
The measurement stays in the live renderer tree and does not enter program or saved state.
Chat widgets omit AdaptiveColumns.

### `ui.Header(style: string, title: string, eyebrow: string, supporting: string, [icon: string]): View`

The app's own title block: eyebrow above, title, supporting line below.

**Styles:** `default` `center`

> Use when the title should lead the screen. A result, visual, or collection can lead instead. Leave eyebrow or supporting as "" when there is nothing to say.

### `ui.Section(style: string, title: string, subtitle: string, children: View[]): View`

One part of the screen, with a role: hero summary content supporting warning.

**Styles:** `content` `hero` `summary` `supporting` `warning`

> Give each part of the screen its own Section and let the role say what the part is for. The spacing between sections comes from the theme, so do not add ui.Spacer between them. Prefer this over a Card when all you want is a titled group.

### `ui.SectionHeader(style: string, title: string, subtitle: string, count: string): View`

A heading inside a section: title, subtitle, and a count on the right.

**Styles:** `default` `accent` `muted`

> Use for hierarchy inside a Section without starting another surface. count is for "3 of 8" and the like; pass "" when there is no count.

### `ui.ListGroup(style: string, title: string, children: View[]): View`

One bounded surface holding related ui.ListItem rows, separated for you.

**Styles:** `default` `compact` `comfortable`

> Two or more related rows belong in one of these, not in a Card each. The frame, the separators and the row rhythm are the renderer's job. Rows are ui.ListItem or ui.IntListItem; a ui.SectionHeader may open the group and a ui.ActionBar may follow the row it belongs to.

### `ui.ListItem(style: string, text: string, label: string, value: string, action: string, eventValue: int, enabled: boolean, [icon: string]): View`

One row of a list: title, subtitle, trailing text, leading icon, tappable.

**Styles:** `default` `accent` `success` `warning` `danger`

### `ui.IntListItem(style: string, title: string, subtitle: string, value: int, prefix: string, suffix: string, minimumDigits: int, action: string, eventValue: int, enabled: boolean, [icon: string]): View`

A ui.ListItem whose trailing value is a number, formatted for you.

**Styles:** `default` `accent` `success` `warning` `danger`

> For a row that ends in a quantity, an amount or a time. It goes in a ui.ListGroup exactly like ui.ListItem. Note it carries two numbers: value is what is shown, eventValue is what the tap hands the handler.

### `ui.Timeline(style: string, title: string, children: View[]): View`

Events in the order they happen, joined by a rail.

**Styles:** `default` `compact` `comfortable`

> For anything that runs in time -- an itinerary, a course of treatment, a history. Prefer it to ui.ListGroup whenever the order is chronological rather than merely grouped. Children are ui.TimelineItem; a ui.ActionBar may follow the entry it belongs to.

### `ui.TimelineItem(style: string, title: string, subtitle: string, trailing: string, action: string, eventValue: int, enabled: boolean, [icon: string]): View`

One moment on a timeline; same fields as ui.ListItem, plus its marker.

**Styles:** `default` `accent` `success` `warning` `danger`

> Put the time in trailing, so the times line up down the right edge. The icon becomes the marker on the rail -- "pin" for a place, "check" for something done, "clock" for something still ahead; with no icon the marker is a plain dot.

### `ui.MetricGroup(style: string, columns: int, children: View[]): View`

Two to four ui.Stat or ui.IntStat children across one surface, in equal columns.

**Styles:** `default` `compact` `spacious`

> The summary strip at the top of a screen. Only ui.Stat or ui.IntStat children. columns is a maximum: a narrow screen uses fewer.

### `ui.Stat(style: string, label: string, value: string, supporting: string, [icon: string]): View`

One number told properly: label above, value large, supporting line below.

**Styles:** `default` `accent` `success` `warning` `danger`

> For a summary figure. It draws no surface of its own, so put two to four inside a ui.MetricGroup rather than one inside a Card.

### `ui.IntStat(style: string, label: string, value: int, prefix: string, suffix: string, minimumDigits: int, supporting: string, [icon: string]): View`

Ui.Stat for a number the program holds as an int.

**Styles:** `default` `accent` `success` `warning` `danger`

> Prefer this to ui.Stat whenever the figure is a number rather than text. Same place: inside a ui.MetricGroup.

### `ui.KeyValueGroup(style: string, columns: int, children: View[]): View`

Ui.KeyValueItem children in equal columns, for facts rather than figures.

**Styles:** `default` `compact` `spacious`

> For the details of a thing -- where, how long, which platform. Use this rather than a ui.MetricGroup when the values are words, and rather than a ListGroup when they are short enough to sit two to a row.

### `ui.KeyValueItem(style: string, label: string, value: string, supporting: string): View`

One labelled fact: label above, value below.

**Styles:** `default` `accent` `success` `warning` `danger`

> Only inside a ui.KeyValueGroup.

### `ui.InsetBanner(style: string, title: string, message: string, actionText: string, action: string, [icon: string]): View`

A standing status or guidance note in a tone, with one optional action.

**Styles:** `default` `accent` `success` `warning` `danger`

> For something that stays true while the person works -- a permission that was refused, a warning, the result of the last call. Pass actionText "" and action "" when there is nothing to tap; the handler, if you name one, is called with 0.

### `ui.EmptyState(style: string, title: string, message: string, actionText: string, action: string, [icon: string]): View`

What to show where a collection is empty: title, message, one way forward.

**Styles:** `default` `muted`

> State starts empty, so this is the first thing the person sees. Put one behind ui.When(list.length() === 0, ...) for every collection the app keeps. Pass actionText "" and action "" when there is nothing to tap; the handler, if you name one, is called with 0.

## Feedback

*loading and transient status*

### `ui.Skeleton(style: string, width: int, height: int, [rounded: boolean]): View`

A placeholder box the size of the content that has not arrived yet.

> Put one where real content will appear once it is ready, instead of leaving that space blank or showing a zero. width and height are the box in points; rounded softens the corners for anything that will end up looking like a chip or an avatar.

### `ui.Spinner(style: string, [label: string]): View`

A small spinning indicator that something is in progress.

**Styles:** `default` `accent`

> For a wait with no useful progress number to show -- reach for ui.Progress instead when there is one. label is shown beside it and may be "".

### `ui.Snackbar(style: string, message: string, actionText: string, action: string): View`

A one-line status strip the program raised itself, with one optional action.

**Styles:** `default` `success` `warning` `danger`

> For something that just happened and does not need to stay on screen -- "Saved", "Undo", a result the person did not have to ask for. Unlike ui.InsetBanner this is not meant to persist: put it behind ui.When(state.showX, ...) and have the handler that triggered it set state.showX true, and whatever dismisses it (a timer, the action button, the next tap) set it back to false. Pass actionText "" and action "" for no action; the handler, if named, is called with 0.

## Chart

*a series of numbers, drawn*

### `ui.Sparkline(style: string, series: int[], maximum: int, label: string, [bars: boolean]): View`

A small line or bar chart from a series of whole numbers.

**Styles:** `default` `accent` `success` `warning` `danger`

> For a trend at a glance -- steps across a week, a balance over time -- rather than a table of numbers nobody will read. series is drawn left to right in the order given; maximum bounds the vertical scale, and a value past it is clamped rather than redrawing everything else smaller. label is shown with the chart and may be "". Leave bars false (the default) for a connected line; pass it true to draw separate bars instead, for a handful of categories compared side by side rather than a trend over time.

## Table

*rows and columns of text*

### `ui.Table(style: string, headers: string[], columns: int, children: View[]): View`

Rows and columns of text, with an optional header row.

> For data that genuinely has columns -- a list of orders with date, item and amount; a schedule with time and place. headers names each column and may be an empty array for no header row; columns should match both headers' length (when given) and every ui.TableRow's own cells length. Children are ui.TableRow. Prefer ui.ListGroup when each row is really just a title with a trailing value -- a table is for three or more columns of data read down as well as across.

### `ui.TableRow(style: string, cells: string[]): View`

One row of a ui.Table: one string per column, in order.

**Styles:** `default` `accent` `success` `warning` `danger`

> Only inside a ui.Table, and always with as many cells as the table has columns. Give it a tone to call out one row, a total line or a problem entry, the same way a ui.ListItem can.

## Navigation

*screen identity and the system back gesture*

### `ui.Screen(id: string, children: View[]): View`

The active screen, with a stable identity. Changing `id` replaces its native controls without restarting the program or replacing shared application state. Same-screen updates retain field identity. Native entry starts at the top; there is no automatic focus-restoration or navigation stack.

Use one named view function per screen, all taking the same AppState. `view(state)` calls only the active function using `if/else`, inside one AppTheme. A handler switches screens by returning updated navigation state. Keep the ID stable while typing; include the record ID for an editor/detail screen. Do not construct inactive screen functions with `ui.When`, whose arguments are evaluated eagerly.

See [Multi-screen runtime](multiscreen-runtime.md) for the contract, a minimal example and regression checks.

### `ui.BackHandler(action: string): View`

Draws nothing; calls the handler, with 0, on the system back gesture.

**Handler receives:** `int`

> VERA has no separate navigation stack -- screens are a state.screen-style field and if/else choosing which named screen function to call, wrapped in ui.Screen. Add one ui.BackHandler wherever a screen other than the first is showing, so the hardware/system back gesture does something sensible (return to the previous screen, close a dialog) instead of the OS default, which exits the app. Leave it out of the first screen so back still exits normally. Only one should be live at a time; if several are drawn in the same frame the last one decoded wins.

## Drawing frame by frame

*a box the program paints itself*

### `ui.Surface(style: string, width: number, height: number, draw: string, frame: string, pointer: string): View`

A box the program draws itself every frame with std/gfx shapes, in its own units, and that a finger can touch: a game, a drawing pad, a simulation, an animated scene.

**Styles:** `default` `fill`

> For anything that moves continuously or is drawn freely: a game, a ball that bounces, a drawing or signature pad, a physics toy, a clock face that sweeps. Not for lists, forms or charts of data -- those have components. width and height are the surface's own units (say 360 by 640 for a phone-shaped game, 100 by 100 for a square): every position the program draws or receives is in them, and the renderer scales the whole surface to fit, so nothing depends on the size of the phone. draw names function draw(state: AppState): gfx.Shape[] -- it returns the shapes back to front and is called for every frame, so it must only read state. frame names function onFrame(state: AppState, elapsedMs: number): AppState, called before every frame (about 60 a second) with the milliseconds since the last one: move things by speed * elapsedMs / 1000 so the speed does not depend on the phone; pass "" for a surface that only changes when touched. pointer names function onPointer(state: AppState, p: gfx.Pointer): AppState, called when a finger goes down, moves, lifts or is cancelled, with p.x and p.y in surface units; pass "" for none. Style fill makes the surface run from where it starts to the bottom of the screen, for a full-screen game: put the score in the drawing, or a ui.Header above it. Keep what the game needs between frames -- positions, speeds, score, a seed for math.randomBelow -- in AppState, and keep the shapes out of it. A tap is a pointer "down" then "up"; a drag is "down", many "move", then "up".

The renderer calls `frame` at the display's own rate (`@ohos.graphics.displaySync`, at most 100 ms reported per
frame), then `draw`, and paints the shapes straight into an ArkUI `Canvas`; `view()` is re-run only every 100 ms
while a surface is running, and the state is saved every 5 s and when a finger lifts. A trap in either function
stops the loop and shows the error, as a ticker's does. The compiler checks the three functions' signatures
(`E2106`), and the smoke run before a program is served draws every surface once and hands the pointer handler a
finger.

### `std/gfx`

Always available as `gfx`. Every position and size is in the surface's own units.

| function | what it draws or returns |
|---|---|
| `gfx.rect(x: number, y: number, width: number, height: number, color: string): Shape` | a filled rectangle; x, y is its top-left corner |
| `gfx.roundRect(x: number, y: number, width: number, height: number, radius: number, color: string): Shape` | a filled rectangle with rounded corners |
| `gfx.circle(x: number, y: number, radius: number, color: string): Shape` | a filled disc centred on x, y |
| `gfx.arc(x: number, y: number, radius: number, startDegrees: number, sweepDegrees: number, lineWidth: number, color: string): Shape` | a stroked arc centred on x, y; 0 degrees is twelve o'clock and angles run clockwise; sweep 360 is a ring |
| `gfx.line(x1: number, y1: number, x2: number, y2: number, lineWidth: number, color: string): Shape` | a straight line with round ends |
| `gfx.polyline(points: number[], lineWidth: number, color: string): Shape` | a stroked open line through [x0, y0, x1, y1, ...]; for a graph, a trail, a drawn stroke |
| `gfx.polygon(points: number[], color: string): Shape` | a filled closed shape through [x0, y0, x1, y1, ...]; for a star, a ship, a mountain |
| `gfx.path(commands: string, color: string): Shape` | a filled SVG path (M L C Q A Z, absolute) in surface units |
| `gfx.strokePath(commands: string, lineWidth: number, color: string): Shape` | an SVG path drawn as a line rather than filled |
| `gfx.text(x: number, y: number, size: number, align: string, color: string, text: string, [bold: boolean]): Shape` | one line of text; align is "left", "center" or "right" about x, and y is the middle of the line |
| `gfx.group(x: number, y: number, rotation: number, scale: number, alpha: number, shapes: Shape[]): Shape` | shapes drawn around their own 0, 0, moved to x, y, turned clockwise by rotation degrees, scaled, and faded by alpha (0..1) |
| `gfx.rgb(red: number, green: number, blue: number, [alpha: number]): string` | a colour from 0..255 channels and an optional 0..1 alpha, for colours computed at run time |
| `gfx.distance(x1: number, y1: number, x2: number, y2: number): number` | the distance between two points |
| `gfx.inside(px: number, py: number, x: number, y: number, width: number, height: number): boolean` | whether point px, py lies in the rectangle x, y, width, height |

`class gfx.Pointer { phase: string; id: number; x: number; y: number }` -- phase is one of
`down`, `move`, `up`, `cancel`.

A colour is a theme role -- `ink` `soft` `muted` `accent` `accentFill` `onAccent` `background` `surface` `line` `success` `warning` `danger` `white` `black` `clear` -- which follows the preset and dark mode,
or `"#rrggbb"` / `"#rrggbbaa"`, or what `gfx.rgb` returns. A literal colour outside these, or an align other than
`left`, `center` or `right`, is diagnostic `E2112`; a computed one that is not a colour is drawn in ink. One
frame draws at most 4000 shapes, groups nest at most 12 deep and a polyline or polygon
holds at most 1000 points; past any of them the frame traps with `R0028`.

Host proofs: `tools/vera-harness/gfx-run.js` plays a program's surface with scripted fingers and draws chosen
frames with the phone's own painter; `tools/vera-harness/gfx-check.js` checks all of the above against
`tools/vera-harness/examples/surface-catch.vera`.

## Beyond the components

- `ui.When(condition: boolean, child: View): View` -- the child when true, nothing when false. This is how a
  program shows one thing or another; there is no `if` inside a view.
- `ui.intToString(n: int): string`, `ui.numberToString(n: number): string`,
  `ui.booleanToString(b: boolean): string` -- the only conversions into text.

### Icon names, the only ones that exist

`check` `close` `plus` `minus` `chevron-right` `navigate` `pin` `calendar` `clock` `star` `user` `warning` `info` `trash` `list` `chart`

Pass `""` where a component takes an icon and none is wanted. An icon is usually a property of a ListItem,
Banner, EmptyState, Header or Stat rather than a component of its own.

### Composition rules the compiler enforces

- ListGroup takes only ListItem, IntListItem, SectionHeader, ActionBar or When children.
- MetricGroup takes only Stat, IntStat or When children.
- KeyValueGroup takes only KeyValueItem or When children.
- Table takes only TableRow or When children.
- Timeline takes only TimelineItem, ActionBar or When children.
- ActionBar takes only Button, IconButton, Badge or When children.
- Card may not contain another Card.
- AppTheme may not contain another AppTheme.

These are checked on the tree the program writes, not at runtime, and the violation is diagnostic `E2107`.

## Keeping this file true

Adding a component means editing `VeraUiCatalog.ets`, adding a case in `VeraUi.ets` and a branch in
`VeraPreview.ets`; the compiler, the validator and the prompt follow from the table on their own. The renderer
keeps its own list of kinds it can draw and complains on startup if the two drift apart. This file is written
from the same table and should be regenerated whenever the table changes.
