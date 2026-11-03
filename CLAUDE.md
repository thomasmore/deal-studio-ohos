# Working on this repo

A HarmonyOS app that generates small programs from a plain-English prompt,
compiles them on the phone and renders them as native ArkUI. `entry/src/main/
ets/vera/` is the language: compiler, VM, the `std/ui` catalogue and the theme.
`entry/src/main/ets/components/VeraPreview.ets` is the renderer.

## Before you build: find out what is missing, then ask

For a rebuild and in-place update, run `./update-phone.sh` directly: it checks
the tools and the installed app before building. Do not repeat the checks below
or reread the build scripts on routine update requests unless the command fails.

For other build workflows, the build needs three things that are not in this
repo. Run this first — it prints what it found and what it did not:

```bash
bash -c 'source ./tool-paths.sh
for t in arkui-hvigor arkui-sign arkui-device-cli; do
  printf "%-18s %s\n" "$t" "$(vera_kit_bin $t 2>&1 | tail -1)"; done
printf "%-18s %s\n" hdc "$(vera_hdc_dir 2>&1 | tail -1)"
printf "%-18s %s\n" hapsigner "$(vera_hapsigner 2>&1 | tail -1)"'
```

| what | used for | how the scripts find it |
|---|---|---|
| **ArkTS Agent Kit** | `arkui-hvigor` builds, `arkui-sign` debug-signs, `arkui-device-cli` dumps the screen | `$KIT_ROOT`, else a few known locations; the binaries live in `tools/` in an unpacked kit and `.venv/bin` in a pip install, and both are searched |
| **hdc** | everything that talks to the phone | `$HDC_DIR`, else `~/Desktop/hdc`, `~/hdc`, else `PATH` |
| **hapsigner** | `sign-system.sh` calls `dist/hap-sign-tool.jar`; needs a JRE | `$HAPSIGNER`, else `~/agent-kit-sdk/hapsigner` |

One more thing is not in this repo and is not checked by that command:
**llama.cpp**, under `entry/src/main/cpp/llama.cpp` (git-ignored). Fetch the commit
pinned in `entry/src/main/cpp/CMakeLists.txt` -- the exact commands are in the
comment at its top. Without it the build still succeeds but produces a stub with
no model support: embedding search for SDK functions and intents falls back to
keywords, and the Generate and Chat screens say so in their status line. After
fetching it, delete `entry/.cxx` once so CMake sees it.

**If any of them prints an ERROR line, stop and ask the person working with you
— do not guess a path and do not install anything.** Ask exactly this:

> This repo needs the ArkTS Agent Kit, hdc and hapsigner, and I cannot find
> *(name the ones that failed)*. Where are they on this machine? I will use them
> through `KIT_ROOT` / `HDC_DIR` / `HAPSIGNER` — or I can add the location to
> `tool-paths.sh` if it should be found automatically from now on.

An explicitly set variable is an instruction, not a hint: if the thing is not
where it says, the script fails and names the variable rather than quietly using
another copy.

## Building, signing, installing

For routine updates:

```bash
./update-phone.sh
```

This requires exactly one connected phone and an existing system installation
with the same bundle name. It builds incrementally, skips debug signing, signs
once with the system profile, installs without deleting anything, and verifies
that the app ID, UID and first install time did not change while update time
advanced. On any error, stop: never uninstall, clear app data, or change the
bundle name to work around an update failure. The script prints elapsed time.

For separate build/sign steps:

```bash
./build-hap.sh --unsigned
./sign-system.sh
hdc install /tmp/vera-probe-dyn-hap/vera-probe-dyn-system-signed.hap
./measure.sh 3
```

Without `--unsigned`, `build-hap.sh` keeps its original debug-signing behaviour
and finds the UDID itself. It cannot produce a system app: `arkui-sign` takes no
profile argument and reads the kit's own template. A program that calls
`std/intent` needs system signing because `insightIntentDriver` is a system API.

For shell-only changes, run:

```bash
for script in build-hap.sh sign-system.sh update-phone.sh tool-paths.sh; do
  bash -n "$script" || exit
done
git diff --check
```

No shell lint/typecheck command is configured; use ShellCheck if it is available.

## Three traps that cost real time

**Never `hdc uninstall`.** It destroys `{filesDir}/vera`: every saved project,
every program's state and the DeepSeek API key. There is no backup route. If an
install is refused, work out why instead — and note that a normal app cannot be
updated into a system app in place (`9568294 apptype not same`), so a bundle that
has ever been installed normally has to be built under a throwaway `bundleName`
to test a system profile.

**The API key is a launch parameter**, never compiled in, and it survives
restarts once stored:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn --ps deepseekKey sk-...
```

`deepseekKey` is the historical name (DeepSeek is the default provider);
`cloudKey` is the provider-neutral alias for any other OpenAI-compatible
chat-completions endpoint, and it carries its own base URL and model:

```bash
hdc shell aa start -a EntryAbility -b com.vera.probe.dyn \
  --ps cloudKey sk-... --ps apiBase https://api.openai.com/v1 --ps apiModel gpt-4o
```

`apiBase` is the prefix up to `/chat/completions` (the engine appends that path
itself); `apiModel` is the `model` field. Both default to DeepSeek's, both
persist across restarts, and the DeepSeek-only `thinking` / `reasoning_effort`
request fields are sent only when the configured endpoint or model is DeepSeek's
(`SettingsStore.isDeepSeek`). `--ps jevProxy 1` is a flag, not a URL: it routes
the composer's selector calls through the in-process proxy (`JevProxy.ets`) so
they are answered by the configured cloud model instead of TypeSafe, reusing the
same `apiBase` / `apiModel` / `cloudKey`.

The same goes for `vera-server`, if the Server generation mode is wanted:
`--ps veraServer http://host:port`. None of these has a default, and none
belongs in the source.

Development launch parameters are ignored when another app starts the ability; only native callers such as `hdc shell aa start` are honoured (see `LaunchTrust.ets`).

**Prompts typed into the Generate screen are written in English**, even when the
conversation is not.

## Internet through the computer (USB network)

When the phone's Wi-Fi is poor, its whole traffic can go over the USB cable:
run `./usb-net.sh` on the computer (needs java; leave it running) and switch
on Generate > Settings > Advanced > **USB network** on the phone. Off by
default; the first start asks the person to allow the VPN.

- The computer side is the relay from gnirehtet (`tools/gnirehtet/`), on
  127.0.0.1:31416. The phone side is ours: `UsbNetAbility.ets` (a
  VpnExtensionAbility) and `libusbnet.so`: `usbnet_tunnel.h` copies IPv4
  packets between the tun and the relay and reconnects by itself,
  `usbnet_packets.h` splits the relay's stream into packets, and
  `napi_usbnet.cpp` is only the NAPI glue.
- Host tests, no phone needed (run both after touching the C++):
  `g++ -std=c++17 -Wall -Wextra -Werror -I entry/src/main/cpp tools/usbnet-packets-test.cpp -o /tmp/t && /tmp/t`,
  and `tools/usbnet-tunnel-test.cpp` (fake tun and relay; the build line for
  ThreadSanitizer and AddressSanitizer is at its top; TSan needs
  `setarch "$(uname -m)" -R` on recent kernels).
- The phone reaches the relay as its own 127.0.0.1:28416 (`hdc rport`), not
  31416: the phone reserves 31150-31950 and hdc cannot listen there.
- Because the app is system-signed, `startVpnExtensionAbility` must carry
  `callingUid`/`callingPid` (`UsbNet.ets`), or every start after the consent
  dialog fails with 2200003.
- Give the VPN no `routes`: netmanager adds the default route itself, and a
  route with an unreachable gateway leaves nothing routed into the tun.
- IPv4 only. Apps go through the VPN; the shell (`hdc shell`) and system
  services running under system UIDs (HMS, for one) do not.
- After `./update-phone.sh` the VPN is gone; switch it on again.
- With several devices attached, run `VERA_PHONE=<serial> ./usb-net.sh`.
- The page and the VPN (separate processes) share two files in filesDir:
  `usbnet-want.txt` (what the person asked for; the VPN stops itself when it
  reads 'off', which settles a stop that raced a start or the consent dialog)
  and `usbnet-status.txt` (written on change). Whether the VPN is up is asked
  of the system, not inferred from the file.

What it exposes, and what it does not:

- Both ends listen on loopback only (127.0.0.1:28416 on the phone,
  127.0.0.1:31416 on the computer); nothing on the Wi-Fi or LAN can reach them.
- While it is on, the phone's apps reach the internet *as the computer*, so
  they also reach whatever the computer's network reaches (its LAN, a VPN it
  is on). They do not reach the computer's own localhost: gnirehtet's relay
  maps 10.0.2.2 there, and `napi_usbnet.cpp` drops every packet to 10.0.2.2.
- Traffic between the phone and the relay is plain IP over the cable; HTTPS
  stays encrypted end to end. Any local program on the computer could also use
  the relay as a way out, which gives it nothing it did not already have.
- `tools/gnirehtet/gnirehtet.jar` is checked against the release's
  SHA256SUMS.txt (see the README beside it). Replace it only the same way.

## Checking things without a device

The ArkTS build leaves plain TypeScript in
`entry/build/default/cache/default/default@CompileArkTS/esmodule/release/entry/src/main/ets/vera/`,
so the compiler, the VM, the UI decoder and the theme all run under node on the
host. That is the fast way to check a change: seconds, no install, no
generation. Two things to know — imports come out as
`"@normalized:N&&&entry/src/main/ets/vera/X&"` and must be rewritten to
`"./X.js"`, and `compileVeraSource` **throws** `CompileError` carrying
`.diagnostics` rather than returning them.

For anything visual, render a proof sheet rather than waiting on a generated app
to happen to contain the thing you changed: a hand-built node tree in the
renderer, or an SVG rasterised on the host. Chasing a layout bug through
minute-long generations does not converge — that mistake has been made here.

## Where the pieces are

| file | what it is |
|---|---|
| `entry/src/main/ets/vera/VeraUiCatalog.ets` | the one description of `std/ui`: components, styles, icons, composition rules. The compiler interface, the validator and the model's prompt are all generated from it |
| `entry/src/main/ets/vera/VeraTheme.ets` | six presets, light and dark, and every colour and size the renderer uses |
| `entry/src/main/ets/vera/VeraGfx.ets` | `std/gfx`, what a `ui.Surface` draws frame by frame: the function table the compiler and the prompt are generated from, the shapes, colours through the theme, fitting, and `paintGfx`, the one painter both the phone's `Canvas` and the host SVG proofs (`tools/vera-harness/gfx-run.js`, `gfx-check.js`) use |
| `entry/src/main/ets/vera/VeraIcons.ets` | sixteen icons as path data, normalised to one optical size |
| `entry/src/main/resources/rawfile/vera-skill.txt` | the prompt, with `{{UI_CATALOG}}` spliced in |
| `docs/demo-prompts.md` | the prompts this is demonstrated with, and what to check in the output |
| `docs/prompts/intent-coverage.md` | 59 prompts that between them reach 596 of the 640 intents this phone has, each with the addresses it should pull in and a table to record what the phone actually did. `tools/prompt-coverage.py` checks it against the pulled `insight_intent.db` on the host — run that before editing a prompt, because the wording is what decides which addresses the model is shown |
| `docs/prompts/block-composition.md` | prompts for the composed blocks (record_log and the readers that take their data from its ports), the layout and blocks each should give, and a column for what the phone did. Blocks, ports, layouts, holes and the composition record are in `VeraTemplates.ets`, `VeraLayouts.ets`, `VeraHoles.ets`, `VeraComposition.ets`; host checks are `tools/vera-harness/{ledger,itinerary,timer,reminders,composition,hole,port-bind,section-pick,verify}-check.js` |
| `docs/agent.md` | how a new screen is built now: the route (`vera/agent/VeraBuildRoute.ets`: the agent, then the whole screen as one hole), the agent (`vera/agent/VeraAgent.ets`, which draws the plan of needs the model writes knowing neither parts nor catalogue, `NeedsPlan.ets`, then chooses the composer's parts and the catalogue's sections for each need, `NeedsChoose.ets`, `chooseSections` in `VeraCompose.ets`, `agent/AgentAlign.ets`), the plan format (`vera/ScreenPlan.ets`), holes the model writes (`vera/agent/AgentHole.ets`, `AgentCustom.ets`), the terms, the measured results and the switches. Host checks `tools/vera-harness/{agent,plan,parts,compose,merge,needs-plan,needs-choose,length-feeders}-check.js` (they need `VERA_TYPESCRIPT_PATH`); live runs `tools/vera-harness/agent-run.js` |
| `docs/prompts/needs-plan-25.md` | 25 fixed short prompts and the first phone run of the old path against the plan of needs, with a verdict for each. The list is fixed: do not reword or add to it after a run, and do not tune a threshold on it |
| `docs/examples/shanghai-layover.vera` | a program the model actually wrote, kept verbatim |
| `usb-net.sh`, `entry/src/main/ets/usbnetability/UsbNetAbility.ets`, `entry/src/main/ets/vera/UsbNet.ets`, `entry/src/main/cpp/{napi_usbnet.cpp,usbnet_tunnel.h,usbnet_packets.h}`, `tools/usbnet-*-test.cpp` | USB network: the phone's whole traffic through the computer (see "Internet through the computer" above) |
| `docs/intent-call-contract.md` | `intent.call`'s signature and its four-shape answer contract (JSON / `"ok"` / `"declined code=N"` / `"error N: ..."`), with two confirmed device cases of generated code checking for `"ok"` or not checking at all — read before touching a handler that reports success or failure |

Adding a component means editing the catalogue, adding a case in
`VeraUi.ets`, and adding a branch in `VeraPreview.ets` — the compiler, the
validator and the prompt follow from the catalogue on their own. The renderer
keeps a second hardcoded list of kinds it can draw and complains on startup if
it drifts from the catalogue.
