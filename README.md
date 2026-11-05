# vera-probe-dynamic

Measures the VERA runtime on a real HarmonyOS device, as a **dynamic**-ArkTS
port. Paired with `webview-probe`, which loads the same two prompts as HTML
into a WebView — same device, same OS build, same clock.

## Why a dynamic port exists

The `'use static'` original (`../vera-probe`) will not run on either device
available:

| device | blocker |
|---|---|
| SGT-AL00, API 22 | SDK 26 emits Panda bytecode 0.1.0.7; the VM accepts ≤ 0.0.0.5 |
| Mate 60 Pro, API 26 | SDK 26.0.0.26 is ABI-incompatible with the device's 26.0.0.37 |

Dynamic ArkTS tolerates both skews — `webview-probe` is dynamic and ran fine on
the API 22 phone. Building for API 26 requires a private environment, so the
target is **API 22**, which is also where the WebView numbers already come from.

## What this does and does not establish

**Does:** a real device measurement of the VERA pipeline — parse, VM boot,
`render()`, decode, ArkUI construction, and resident memory — directly
comparable to the WebView cost measured on the same phone.

**Does not:** measure the runtime the VERA product targets. Static ArkTS runs on
the Panda static VM (`modules_static.abc`); dynamic ArkTS runs on the
ArkCompiler JS-style engine (`modules.abc`). These are different runtimes, and
the host measurement of 435 µs parse+boot was taken on the static one. So these
numbers must not be blended with the host static figures — quote them as the
dynamic-ArkTS device cost, and treat the static-vs-dynamic gap as the remaining
open question.

## The port

`entry/src/main/ets/vera/` is a mechanical port of the static runtime in
`vera-static-hello` — same algorithm and control flow, only the type system
differs:

| static | dynamic |
|---|---|
| `'use static'` | removed |
| `final class` | `class` |
| `int`, `double` | `number` |
| `Any` | `Object \| null \| undefined` |
| `x instanceof number` | `typeof x === 'number'` |
| `Int.toDouble(a & b)` | `a & b` — JS bitwise already yields a number |
| `JSON.parseJsonElement` | `JSON.parse` — the JsonElement API does not exist here |

`parseConstant` was rewritten rather than translated. The static version handled
only null, string, boolean, number and `BytecodeFunction`, so array and plain
object constants fell through to `Unsupported constant value`. That gap is now
closed. **This is not known to be the cause of the `pairs` failure** seen on the
real runtime: that artifact contains no container constants at all (16 numbers,
43 strings, 1 boolean, 8 functions), so that bug is still unexplained.

The port compiles clean (`status: ok`, 0 diagnostics) but **has not yet been run
on a device**, so its output has not been checked against the reference
implementation. First run should confirm the rendered tree matches what
`vera-bench` produces on the host before any timing is quoted.

## Generation modes

The Generate screen cycles through three ways to turn a prompt into a VERA-L
program. The button top-left switches between them.

| mode | model | who writes the code |
|---|---|---|
| `DeepSeek` | `deepseek-flash` over HTTPS | the device: generate, compile, feed diagnostics back, retry |
| `Local` | Qwen2.5-Coder-3B in-process via llama.cpp | the device, same loop |
| `Server` | whatever `vera-server` runs | the server, which returns finished vbc2 |

DeepSeek and Local are the same agent loop — `compileVeraSource` runs on the
phone, compiler diagnostics go back to the model, up to three attempts — and
differ only in where the model lives. Server is the original path and is kept
for comparison: there the phone only ships a prompt and receives bytecode.

DeepSeek has no GBNF grammar to constrain decoding the way llama.cpp does, so
`vera.gbnf` is unused in that mode; the reply is cleaned up by
`extractVeraSource` in case the model wraps the program in a markdown fence.

### The API key

The key is not compiled in. It is sent as a launch parameter and stored in the
app sandbox at `{filesDir}/vera/settings.json`:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
  --ps deepseekKey sk-...
```

Once stored it survives restarts, and the app never logs it — the status line
shows only `sk-...abcd`, enough to confirm it arrived. Storing it this way keeps
it out of git and out of the HAP, but it is not a secret against someone holding
the unlocked phone: on a debug-signed install `hdc` can read the sandbox. Use a
key dedicated to this project and revoke it in the DeepSeek console if the phone
leaves your hands.

The same file holds `model` and `baseUrl`, so pointing the app at another
OpenAI-compatible endpoint needs no rebuild.

`vera-server`'s address is supplied the same way and kept in the same file:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
  --ps veraServer http://host:port
```

There is no default. It used to be one machine's address written into the
source, which meant nothing to anyone else; with none given, Server mode says
so and the other two modes are unaffected.

### Launch parameters

Everything the app takes from outside is a `--ps name value` pair on
`aa start`, and several go in one start:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
  --ps deepseekKey sk-... --ps typesafeKey ... --ps exaKey ...
```

`EntryAbility.ets` reads them on a cold start and again when the app is
already running. The keys, the effort and the server address are stored in
`{filesDir}/vera/settings.json` and survive restarts; an empty value is
ignored, so there is no way to clear one from the command line. The switches
last only until the app is stopped. A switch is off for `0`, `false` or `off`
and on for anything else.

Keys and settings, kept across restarts:

| parameter | value | what it does |
|---|---|---|
| `deepseekKey` | `sk-...` | the DeepSeek key, for generation, the agent's plan and the sections the model writes. Without it DeepSeek mode cannot generate |
| `typesafeKey` | key | the TypeSafe key for Jev: which intents a request needs, which ready-made sections and parts build a screen, and the checks of what was built. Optional: without it those steps are skipped and the model writes the program |
| `exaKey` | key | the Exa key for web search: the chat's search tool and the sections that look up real data. Optional |
| `reasoningEffort` | `low` \| `high` \| `max` \| `default` | how hard DeepSeek reasons when thinking is on; DeepSeek also takes `minimal`, `medium`, `xhigh`, `ultra` as aliases. `default` goes back to the app's own, `low` |
| `veraServer` | `http://host:port` | where `vera-server` runs, for Server mode |

Switches for comparing paths, until the app is stopped:

| parameter | default | off means |
|---|---|---|
| `veraCompose` | on | the agent is not tried: a new screen goes to the blocks or to the model (the agent also needs `typesafeKey`) |
| `veraComposePlan` | on | when the agent cannot build a screen, the model writing it from scratch is not given the agent's plan |
| `veraCustom` | on | what nothing ready does is not written as a section by the model |
| `veraWhole` | on | when nothing ready fits, the whole screen is not written as one section before generating from scratch |
| `veraTemplateSelect` | on | no blocks path (Jev's pick of ready-made sections) |
| `veraOrder` | `agent-first` | `blocks-first` tries the blocks before the agent |

Opening a saved project, as a home-screen widget does:

| parameter | value | what it does |
|---|---|---|
| `projectId` | project id | opens that project |
| `veraRun` | `1` | with `projectId`: also runs its latest version, on top of the project's page |
| `veraFormId` | form id | opens the page that binds a home-screen widget to a project |

Development probes, one run each, logged to hilog:

| parameter | value | what it does |
|---|---|---|
| `probeTarget`, `probeParams`, `probeMode` | intent, JSON, `background` \| `foreground` | calls one intent, to try a catalogue row before writing it (`IntentProbe.ets`) |
| `probeSdkTarget`, `probeSdkParams` | `sdk.call` target, JSON | calls one SDK adapter directly (`VeraSdkProbe.ets`) |
| `probeSdkSearch` | a need, in words | ranks `find_sdk_function`'s answers for it |
| `veraBenchmark` | `1` | times the search (`VeraSearchBenchmark.ets`) once the caches are warm |
| `veraSdkEval` | `1` | dumps the SDK search's rankings for the gold needs (`VeraSdkEval.ets`) |
| `veraUiEval` | `1` | scores the UI component selector on the gold prompts (`VeraUiEval.ets`) |
| `veraUiAb` | `1` | compares the UI selection modes (`VeraUiAb.ets`) |

## Running it

Three things are needed and none of them is in this repo: the **ArkTS Agent
Kit** (`arkui-hvigor`, `arkui-sign`, `arkui-device-cli`), **hdc**, and
**hapsigner** with a JRE, for system signing. The scripts look for all three
rather than assuming a location — `tool-paths.sh` does the looking, and
`KIT_ROOT`, `HDC_DIR` and `HAPSIGNER` override it. To see what it finds here:

```bash
bash -c 'source ./tool-paths.sh
for t in arkui-hvigor arkui-sign arkui-device-cli; do
  printf "%-18s %s\n" "$t" "$(vera_kit_bin $t 2>&1 | tail -1)"; done
printf "%-18s %s\n" hdc "$(vera_hdc_dir 2>&1 | tail -1)"
printf "%-18s %s\n" hapsigner "$(vera_hapsigner 2>&1 | tail -1)"'
```

```bash
./build-hap.sh      # builds and signs; finds the UDID itself
./measure.sh 3      # 3 cold reps per program -> results/device.jsonl
```

Sign with `--mode debug` for API 22. On an API 26 device AppGallery installs a
disposed rule against debug-signed sideloaded apps and AMS refuses the launch;
`--mode release` yields `os_integration`, which its risk control leaves alone.

### System signing, for std/intent

`insightIntentDriver` is a system API, so a program that calls `std/intent`
needs the app to be a system app. `build-hap.sh` cannot produce one:
`arkui-sign` takes no profile argument and reads the kit's own template.

```bash
./build-hap.sh        # ignore the HAP it signs; we want the unsigned one
./sign-system.sh      # signs with signing/UnsgnedReleasedProfileTemplate.json
hdc install /tmp/vera-probe-dyn-hap/vera-probe-dyn-system-signed.hap
```

That profile differs from the kit's release template in exactly four fields:
`apl: system_basic`, `app-feature: hos_system_app`, the four entries in
`acls.allowed-acls`, and the bundle name. **Take the certificate from the kit's
own template, not from another project's profile** — `appId` is derived from
`distribution-certificate`, and a different one fails as
`9568332 install sign info inconsistent`, which reads like a signing bug and is
not one.

The permissions in `module.json5` are granted by that profile or not at all, and
the device decides at install time. A normal build declaring them is refused
outright (`install failed due to grant request permissions failed`), so the
install output is the test: `install bundle successfully` means the profile was
accepted.

An already-installed normal build cannot be updated into a system one —
`9568294 install failed due to apptype not same`. It has to be uninstalled
first, and `hdc uninstall` destroys `{filesDir}/vera`: every project, every
saved program state, and the stored API key. The sandbox is not readable from
`hdc shell` on a release-signed build, so there is no backup route. To test a
profile without risking any of that, build under a throwaway `bundleName` and
install alongside.

To confirm afterwards:

```bash
hdc shell bm dump -n com.vera.probe.dyn      # isSystemApp, appPrivilegeLevel
hdc shell atm dump -t <accessTokenId> -b com.vera.probe.dyn   # grantStatus 0
```

## What it measures

| metric | from |
|---|---|
| `parseUs` | `parseBytecodeAssembly(vbc1)` |
| `bootUs` | `new VeraVM(program)` + `run()` |
| `renderUs` | `invokeFunction('render')` |
| `decodeUs` | `decodeVeraUi` — validation and UI-node decode |
| `coldTotalUs` | the four above, first pass, nothing warm |
| `warmTotalUs` | same pipeline, mean of 100 iterations |
| `buildUs` | state write to ArkUI `onAppear`: the construction term |
| `pssDeltaKb` | `hidebug.getPss()` before vs after |

Timing uses `getUptime(TimeType.STARTUP, true)` — nanoseconds. The phases are
microsecond-scale, so millisecond resolution would floor them all to zero.

The programs are the exact artifacts the benchmark scored, compiled to vbc1 and
embedded as literals so the timed region has no network and no file I/O:
`tictactoe` (6557 B) and `dashboard` (1439 B) from `results/cortex5`.
