# Multi-screen runtime

One VERA module owns one VM and one shared AppState. Named screens are views of that state, not separate programs. Navigation uses ordinary handlers and a state field; there is no navigation stack or separate store.

## Screen identity

`ui.Screen(id, children)` marks a native subtree boundary. Keep its ID stable for updates within a view; include a stable record ID when opening the same editor for a different record, for example `"editor:" + selectedId`.

- Same-screen redraws retain native controls.
- An identity change remounts child controls, discards old field controllers/pending edits, removes outgoing surfaces and screen-scoped tickers, and resets page scroll.
- Stale input/action callbacks cannot act on replacement controls. Returning to an old screen ID does not revive old callbacks.
- Application-scoped SDK callbacks and tickers can still update shared state; their handlers must preserve current navigation and unrelated drafts.
- Only construct the active view. Use if/else, not eager `ui.When`. A tab shell uses the active Screen at its selected index and empty Columns elsewhere.

Use `ui.BackHandler` on secondary pages to return or cancel the draft; leave it off the starting page so system Back can exit normally. Native identity does not provide draft transactions: the program must copy records into drafts and commit/cancel explicitly.

## Minimal example

```typescript
import * as ui from "std/ui"
@jsonable
class AppState { screen: string; count: number; }
function init(): AppState { return {screen: "home", count: 0}; }
function open(state: AppState, value: number): AppState {
  return {screen: "detail", count: state.count};
}
function back(state: AppState, value: number): AppState {
  return {screen: "home", count: state.count};
}
function add(state: AppState, value: number): AppState {
  return {screen: state.screen, count: state.count + 1};
}
function view(state: AppState): ui.View {
  if (state.screen === "detail") {
    return ui.AppTheme("clean", "", [ui.Screen("detail", [
      ui.Text("body", ui.numberToString(state.count)),
      ui.Button("primary", "Add", "add", 0, true),
      ui.BackHandler("back")
    ])]);
  }
  return ui.AppTheme("clean", "", [ui.Screen("home", [
    ui.Text("heading", "Counter"),
    ui.Button("primary", "Open", "open", 0, true)
  ])]);
}
```

## Checks and limits

`node tools/vera-harness/multiscreen-check.js` exercises shared state, same-screen retention, remounting, stale inputs/actions, surface teardown, screen/global ticker lifetimes and Back using the real VM and extracted renderer methods. `proof-sheet.js` understands Screen boundaries for approximate host SVG proofs; it is not native rendering evidence.

There is no scroll cache, focus-restoration stack, generic transaction framework or navigation animation API. Host regressions do not establish every generated app's behavior. See [multi-view generation](multiscreen-agent.md) for planning, reachability and repairs.
