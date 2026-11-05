# Live sources: a program that fetches its own figures

A request for a figure of the real world (the weather, an index, a rate, a price) used to give a program with the figures of a
search made once, at generation, written into it: "Live IMOEX value" showed 2488.71 for good and said so in a banner, and its
widget returned the constant 2515.89. Now Generate looks for a **live source** first -- a public JSON API that needs no key --
and the program fetches it itself, on the screen and on its home-screen card.

## Finding a source (`vera/VeraSourceFind.ets`, at generation)

Run when `LIVE_QUERY_PROMPT` (LiveFigures.ets) says the request needs a current figure, before the old search-and-write path,
which stays as the fallback:

1. One web search: the figure plus "free public JSON API no API key".
2. DeepSeek (`SOURCE_FIND_PROMPT`, no thinking) proposes up to three GET addresses with every parameter filled in.
3. Each is fetched (`httpGetText`: https only, no credentials in it, no host on this network, size limit, short timeouts). A
   JSON answer is shown to DeepSeek as a sample (`sampleOf`: lists of records cut to three, a list of plain values -- column
   names, a row -- kept to sixty), and it names where each figure is: a path such as `marketdata.data[0][4]`, a label, a unit,
   and the path of the time the data is for (`SOURCE_PICK_PROMPT`).
4. The address is fetched again and the host reads the paths itself. A source is taken only when every path holds a value.
   The model never gives a figure; it only says where one is.

The program is written by the generation prompt with `sourceNote` added: the exact call, what it answered just now, and the
shape of a program that keeps fetching (a ticker, a Refresh button, the answer handler with the place of every line).
Two checks send a program back with the reason, as a compile error is:

- `sourceUseError`: it must make the call as given, and have a `ui.Ticker`, or it never fetches by itself.
- `sourceShownError`: its handler is given an answer of the source's shape with a different figure and time, and the screen
  must then show that figure, the source's domain and that time. A handler that reads the answer's lines in the wrong places
  keeps the figures it started with, and was the commonest mistake.

## No API found: the program reads a search (`Vera.Live.fetch`)

When the finder finds nothing, the search the live-figure check already makes (`webSearch`) gives the first figures, and the
program is written around `sdk.call("Vera.Live.fetch", ["query", <the query>, "labels", "A|B|C"], handler)` (`searchSpec`,
`sourceNote`): on each refresh the phone searches, DeepSeek reads up to three figures off the results, and only a figure whose
text is in the result it names is given (`VeraLive.ets`). The answer has the same lines, so the program and its checks are
the same; the check's answer carries a figure written as a page writes one (`$1,234.56`), and two more refusals came from host
runs: more than three labels (the fourth would read the source line as a figure), and a screen that shows a `source`/`asof`
line as it came. The query and labels must be written out too (E2114). A search refresh costs a search and a model call and
takes 3-10 s, so the program refreshes every five minutes at most, and its widget does not refresh on the card: Make widget is
told not to call it there, and the card shows what the app fetched last. Only a search that found nothing at generation goes
on to the agent. The `live_facts` block, which did this as a section of a composed screen, is removed: no request reached it
once current figures were handled before the route.

Host runs (`source-run.js`, falling back as Generate does): Tesla stock price -- no keyless API (403, end-of-day only), read off a
search: `$401.68` from exa.ai's market page, the program on its first attempt once the check carried a figure with a currency
sign (before that, `strings.toNumber("$401.83")` gave the fallback and the screen kept the first figure); the current Real
Madrid score -- no API (403s), first figures from the search at generation (0-3, FT), the refresh's search did not contain them
and the screen said "Source unavailable" and kept them.

## The call (`vera/VeraSource.ets`, on the phone)

```
sdk.call("Vera.Source.fetch", ["url", "https://...", "paths", "a.b|c[0][1]", "asof", "d"], "onSource")
```

One GET, read at the paths. The answer has the lines of `Vera.Live.fetch`: `ok`, up to three figures (an empty line for one not
asked), `source<TAB>domain<TAB>address`, `asof<TAB>time`; or one line `error: ...`. The compiler takes the parameters only as
written-out strings (E2114), so nothing the program keeps can go out in an address. E2114 applies to `Vera.Live.fetch`'s query
and labels too: a saved program that built its query from its state stops compiling on its next change.

The address comes from a model reading web pages, which a page can steer, so it is held to a public host twice:
`sourceUrlError` (at generation and before each request) refuses a host written as a number in any form (decimal, octal or hex
IPv4, IPv6), `localhost` and local names (`.local`, `.lan`, `.internal`, `.home.arpa`, ...), a trailing dot ignored; on the
phone `publicHostError` resolves the name and refuses it when any address is loopback, private, link-local, CGNAT or
unique-local. Redirects are not followed (`maxRedirects: 0`): a 3xx is an error. A name that resolves differently between the
check and the request (DNS rebinding) is not covered.

## On the card

`widgetRefresh` may make this one call (and no other phone effect), and so may a widget's button (a Refresh): the card
(`LiveFormService`) makes it, hands the answer to the handler, then draws and saves. One call per refresh or tap, with 3 s to
connect and 4 s to read: the card's update has about ten seconds. The answer is handed to the state saved by the time it
arrives: when the app saved during the fetch, its state is kept and the answer applied to it. The once-per-period mark is set
before the fetch, so cards of one project updated together fetch once. Make widget tells the model so; its check
answers the call with a failure, which the handler must take and still draw. The card's update runs `widgetRefresh` when the card
is added and then about every 30 minutes (once per project per 20 minutes, `RefreshLedger`).

## Measured

Host (`tools/vera-harness/source-run.js`: finder, program, then the program run with its own ticker and the real GET), deepseek-
flash, 2026-11-03, one run each, after the fixes below: Moscow weather (Open-Meteo), IMOEX (MOEX ISS), USD/RUB (frankfurter.dev),
Bitcoin (CoinMarketCap's public API), Beijing air quality (beijing.gov.cn), ISS position (wheretheiss.at): 6/6 found, written on the
first attempt, fetched by their own ticker a second after opening and shown with the source and the time; 10-15 s from request to
program, the GET itself 0.1-0.8 s. A source for a live Apple share price was not found (403, end-of-day only, 404).

Phone (Generate screen, then Make widget, Add widget):

| | result |
|---|---|
| Current weather in Moscow, auto-updated regularly | Open-Meteo; compiled on attempt 1; 0.9 °C fetched by the app in 248 ms; widget written; the card fetched it itself when added (241 ms) |
| Live IMOEX value | MOEX ISS; compiled on attempt 1; 2431.47 and its time fetched by the app; widget with a Refresh button written in 2.5 s; the card fetched when added (2432.74, 608 ms) and on its Refresh (2432.51, 1.35 s from tap to redraw) |

Found and fixed on the way:

- The sample cut every list to three items, so MOEX's column list stopped at `LASTVALUE` (the previous close) and the live
  `CURRENTVALUE` was never seen: the app showed yesterday's 2455.62 with "0.00 since previous reading".
- The first phone IMOEX app read the time from the line of the (empty) second figure: its value moved, its time never did.
  Hence `sourceShownError`.
- Make widget took three answers on the weather app: the model closed `import * as time from "std/time";` with a semicolon,
  which does not parse, and was told only "does not parse". The semicolon is now dropped and the parser's message passed on;
  host replay 6/6 on the first answer (~2 s).

Host checks: `source-check.js` (mocked search, model and network), `live-form-check.js` (the card's refresh and Refresh tap with
a mocked fetch), `widget-refine-check.js` (what a widget may call), example `tools/vera-harness/examples/widget-source.vera`.

## Limits

- Only what a free, keyless JSON API gives now is fetched on the card. Without one (live share prices outside MOEX, scores)
  the program reads a search on each refresh, which needs the Exa and DeepSeek keys on the phone, and its widget shows the
  figures the app fetched last. The finder can also take an end-of-day API for a "live" price (an Apple close from
  fin-node.net once; the same site was refused as not real-time on another run).
- The source is whatever the search turned up; an official one is preferred but not guaranteed (Bitcoin came from
  CoinMarketCap's public endpoint, air quality from the Beijing government's own page).
- At most three figures per source. A code (an Open-Meteo weather code) has to be turned into words by the program; when the
  three figures chosen did not include one, the weather widget described the wind instead.
- A free API can change or go away: the program then shows "error: ..." and keeps its last figures.
- The periodic update of a card already on the home screen follows the system's 30-minute schedule. Seen once on the phone: the
  weather card added at 14:44 was updated by the system at 15:16:49 and fetched Open-Meteo itself (374 ms), 0.9 °C to 0.6 °C.
