# Handbeam Probe — Mob Android experiment

> Update this file in the same commit if a change contradicts it.

Mob native UI experiment around **on-device Handbeam runtime**. Not a battery logger.
`HomeScreen` renders native Compose controls via Mob (no LiveView/WebView).
`Handbeam.Application` still owns Coordinator / Runner / Turn. Do not put the agent
loop in the screen process. Chat/history, Model/AI settings (catalog, defaults,
memory, workspace allowlist), workspace add/switch (private folder, accessible
directory, SAF copy import), native tool approval, and shared attachment
foundations (composer context, controlled import descriptors, transcript refs,
export snapshot APIs) are implemented. Photo Picker (max 4 images) and system
share intake (SEND/SEND_MULTIPLE, pending review, confirm-into-draft, send ack)
are wired on native Mob+Compose. Running Send / IME return is **steer** (next
LLM step); an explicit composer chip queues **follow_up**. The running composer
keeps Stop and Send together. Pending queued / undelivered status, undo, and
resend sit on the user bubble via `NativeChat` + `Handbeam.Agent.PendingMessages`.
Pending draft images show compact local thumbs
near the composer (tap opens a larger local card). Sent user images show a
right-aligned thumb row above the bubble, resolved from conversation upload
refs. Mob JSON carries only a local path. All SEND/SEND_MULTIPLE shares enter
one durable ShareIntake FIFO (manifest is the source of truth; notify only
wakes the screen). Review order is `created_at` then persisted `created_seq`.
Cancelled/acknowledged cleanup leaves a durable receipt under
`share_intake/receipts/` so a missing manifest is not treated as unimported.
Workspace copy keeps the original workspace/conversation target; late results
must not merge a switched draft. Copy jobs are supervised (`ShareCopy`);
recursive cleanup/rollback is backgrounded. Neither confirmation sends a message. The review card shows the current
workspace name and conversation title (empty title reads as a new
conversation). The composer is chat-only. Camera/document picker/voice remain
later work. System-browser open (`android_open_url`) and
artifact open/share (`android_open_file` / `android_share_file`) are wired through
ExportSnapshot + isolated FileProvider; they report UI presentation only.
Assistant long-press still offers `复制全文`. Chat bubbles do not show a
**Share text** button. Artifact **Share file** still goes through
ExportSnapshot / `share_snapshot` (`request_id` + generation) and only
claims the chooser opened.

Native file viewer is wired: chat artifact **Open** and the workspace file
tree share `NativeWorkspaceOpen` → `NativeFileViewer`. Android keeps bytes
on-device (`:file_viewer` node). iOS renders the same identity with stock
Mob nodes and a bounded in-app preview (text UTF-8 capped at 1 MiB, local
`:image` path under the 32 MiB encoded cap). PDF and other name-routed
external files, plus **Open in another app** / **Share**, reuse
`NativeArtifactDelivery` (the UI tap path; `AndroidIntent` is the Agent-tool
adapter over the same `Platform.open_url_request/4` / `present_request/6`) →
`Platform.export_file/5` then snake_case `snapshot_id` /
`owner_request_id` for `open_snapshot` / `share_snapshot`. iOS export copies
into an in-process snapshot registry and presents via `handbeam_ios` /
`UIDocumentInteractionController` / `UIActivityViewController`. HTML/MD are
in-app source, not a web preview. User taps skip tool approval. Closing the
viewer returns to the previous page without stopping the Runner or clearing
the draft. The tree lists one directory at a time (expand, hidden toggle,
refresh, load-more). No built-in PDF viewer and no second export provider.

Assistant messages and streaming text use Markwon native TextView spans hosted in
Compose (`NativeMarkdown.kt`), not a WebView. Code blocks have native copy controls;
whole-reply copying retains the original Markdown. Images do not auto-fetch.

Native tool approvals use `NativeApproval` and the existing Coordinator resume /
WorkspaceSettings permission APIs. The review dialog supports once/session/always
allow and once/always deny; dismissing it leaves the Runner waiting. Reopening a
conversation restores live pending approvals from Session events. The chat permission
selector changes workspace default mode, never silently approves a pending request.

Pin: Mob **0.7.39**, `mob_dev` 0.6.33, `mob_new` 0.4.32, Elixir 1.20 / OTP 29.

## Mob Dev

Do not copy or summarize Mob Dev into this repo. Read the pinned
tooling docs, then apply the Handbeam Probe overrides below.

- Upstream README: https://github.com/GenericJam/mob_dev/blob/master/README.md
- HexDocs: https://hexdocs.pm/mob_dev
- This pin on disk: `deps/mob_dev/README.md` (use it if GitHub `master` has moved)
- Device inspection APIs (`Mob.Test`, `Mob.Diag`) live in **`:mob`**, not
  `:mob_dev`: https://hexdocs.pm/mob/Mob.Test.html
- Extra Mix tasks on this pin (`doctor`, `snapshot_loaded`, `cache`,
  `emulators`, `styles`, `trace_otp`, `verify_strip`, …) are listed by
  `mix help` in `mobile/`

Overrides vs the upstream defaults:

- Pack/install the nativechat APK with `mix mob.pack_apk` /
  `script/pack_android_apks.sh`. Do not treat `mix mob.deploy` /
  `mix mob.push` as the ARC persistence path (`run-as` is disabled).
- Do not run default `mix mob.connect`. It restarts
  `MobDev.Config.bundle_id()` (often the original probe), not
  `com.example.handbeam_probe.nativechat`. Open Dist tunnels by hand
  (next section), then `Node.ping/1` + `Mob.Test.*`.
- Debug node `:"handbeam_probe_android_nativechat@127.0.0.1"`, Dist **9200**,
  cookie `:mob_secret`. Bare `:"handbeam_probe_android@127.0.0.1"` usually
  does not connect. iOS simulator node is
  `:"handbeam_probe_ios_<8-char-udid>@127.0.0.1"` (first 8 hex chars of the UDID,
  lowercase, no dashes). Bare `:"handbeam_probe_ios@127.0.0.1"` is only the
  fallback when no UDID is known.
- Host inspect script (no taps): `mix run --no-start script/mob_debug_probe.exs`
  after the 9200/4369 tunnels and a cold start.

## Layout

```
lib/handbeam_probe/app.ex          on_start: DNS NIF + castore CA + start :handbeam, Dist, HandbeamProbe.TaskSupervisor
lib/handbeam_probe/req_dns.ex      Req plugin: Mob.DNS.resolve/1 before Finch connect
lib/handbeam_probe/home_screen.ex  native chat/navigation and UI event handling
lib/handbeam_probe/native_chat.ex  Coordinator intents + transcript/stream projection
lib/handbeam_probe/native_timeline.ex native messages/tool groups via WorkTimeline; sent image thumbs
lib/handbeam_probe/work_timeline.ex display-only native work segments and activities
lib/handbeam_probe/native_local_image.ex local Mob image nodes (draft path vs upload ref)
lib/handbeam_probe/model_settings.ex native forms → existing ModelConfig/Settings
lib/handbeam_probe/native_workspaces.ex list/create/add/switch, drafts, cold-start preference
lib/handbeam_probe/native_workspace_import.ex SAF/host copy request ids and rollback
lib/handbeam_probe/native_folder_browser.ex in-app readable-directory picker
lib/handbeam_probe/share_intake.ex durable share FIFO, receipts/tombstones, async cleanup
lib/handbeam_probe/share_intake_lock.ex serializes Elixir intake writes
lib/handbeam_probe/share_confirm.ex confirm/cancel/workspace-copy outcomes
lib/handbeam_probe/share_copy.ex copy/rollback jobs; review only after successful rollback
lib/handbeam_probe/share_workspace_import.ex confirmed general-file workspace copy
lib/handbeam_probe/native_composer.ex composer draft + local image thumbs/preview + name chips
lib/handbeam_probe/writing_photo_reviews.ex packed review skill read + user-visible compose
lib/handbeam_probe/platform.ex     narrow async import/export commands (fake on host)
lib/handbeam_probe/native_ui.ex    shared Mob node constructors
lib/handbeam_probe/native_file_viewer.ex  read-only viewer metadata/nodes
lib/handbeam_probe/native_workspace_open.ex  shared chat/tree open + viewer overlay
lib/handbeam_probe/native_workspace_tree.ex  current-workspace listing (not recursive)
lib/handbeam_probe/native_artifact_delivery.ex  UI open-url / open-file / share-file + approval exports
lib/handbeam_probe/android_intent.ex  thin Agent-tool adapter over the same Platform requests
lib/handbeam_probe/bridge/inbound.ex  single decode of host messages (engine_result / notification / files picked)
lib/handbeam_probe/bridge/payload.ex  string-key normalisation of sigil payloads; canonical attachment map
lib/handbeam_probe/pending_requests.ex  one correlation table: {ref, kind, scope, generation, deadline}
lib/handbeam_probe/home_screen/requests.ex  socket facade over pending_requests (track/take/bump/expire)
lib/mix/tasks/mob.pack_apk.ex   ARC: OTP zip + sigil priv/static + lib/castore priv/cacerts.pem
config/mob.exs.template         checked-in static_nifs; ci_setup copies to gitignored mob.exs
../lib/handbeam/                   Phoenix + Coordinator / Runner / Turn
../lib/handbeam/workspace_files.ex path resolve / name classify / listing
android/                        Android Gradle host (Compose + JNI + WebView)
android/.../workspace/          fd-gated text/image viewer (`file_viewer` on MobBridge)
ios/                            iOS Mob host (SwiftUI)
```

Do not put the tick loop, HTTP, or an LLM turn in `HomeScreen`. Mob does not
OTP-supervise screens; a screen crash loses assigns. Long work stays under
`Handbeam.Application`.

Inbound decoding happens once. Every `handle_info/2` message passes
`HandbeamProbe.Bridge.Inbound.decode/1` (fixed key whitelists, no
`String.to_atom/1`); sigil event payloads / transcript entries are read through
`HandbeamProbe.Bridge.Payload.string_keys/1` / `attachment/1` and
`Handbeam.TranscriptEntry`. Never write `m[:k] || m["k"]`, a `value/2` / `field/2`
dual-key helper, or a `tool || tool_name` alias chain in `lib/` — `guard_test.exs`
fails on them. Every off-screen reply (platform request id or task ref) is
registered in `HandbeamProbe.PendingRequests` through `HomeScreen.Requests`; the
wire `generation` must match and the scope (`:composer`, `:workspace_open`,
`:share_intakes_ready`, `:models`, `:folder_listed`) must not have been bumped,
otherwise the reply is dropped. Deadlines send `{:pending_request_timeout, ref}`.

`HandbeamProbe.App` writes `Handbeam.Host` once at boot. Desktop Mix never sets
`:host`, so shell/browser stay on. The phone sets `shell/terminal/desktop_browser/
beam_eval/mcp` false, `webview_browser` true, `system_intents` true, and
`directory_picker: HandbeamProbe.DirectoryPicker`. Do not sniff `MOB_DATA_DIR` in
Handbeam. Do not register Terminal or bash on device. `run_elixir_script` is
seeded with `Host.system_intents?` (falls back to `webview_browser?` when
undeclared): Agent writes a workspace `.exs` via `write`/`edit`, then evaluates
it on the installed Android OTP with `args`/`workspace` bindings (no
`System.argv`, no global `File.cd`). It is host-privileged, not `beam_eval`
and not a sandbox. The independent WebView
`browser` tool and `preview_serve` are not `Mob.UI.webview` and must not be
wired into HomeScreen.

NimbleCSV is a runtime dependency bundled into both APK ABIs. Scripts use
`NimbleCSV.RFC4180` for quoted/multiline CSV, not manual comma splitting.
The script tool description advertises it only when loadable; `skip_headers: false`
retains headers and `dump_to_iodata/1` writes correctly escaped fields.

`Handbeam.Tool.ScriptEnvironment` is the single source for curated script APIs,
runtime versions, path/install constraints and examples. Registry snapshots
this into `run_elixir_script`'s description, including with custom system prompts.
The system prompt only points to the tool. When Mix is present, the script tool
allows `Mix.install` from `.exs` for host-compatible pure Elixir/Erlang Hex
packages. `mix_project` is a builtin Agent tool; long Mix work
is owned by `Handbeam.Workspace.MixOwner`, never HomeScreen. Packaged Mix/Hex/ExUnit
live in `priv/mix_toolchain` (copied by `mix handbeam.pack_mix_toolchain` during
`mix mob.pack_apk`). Hex 2.4.1 HTTP on device uses `Handbeam.Workspace.HexHttp`
(Req, public Hex GET/HEAD only); do not start `:inets` for Hex. The Android host
declares `script_http: :platform_dns_ca` after configuring Req DNS and CA
certificates, before starting Handbeam/tool registration. Availability does not
promise that every operation or network destination will succeed.

## Host loop (no device)

```bash
cd mobile
mix deps.get
mix test
```

Tests must not load Android NIFs. Persist via Ecto; inject clocks with opts,
not `Process.sleep`.

## Inspecting the running app — Layer 1 first

The UI is a GenServer on an Erlang node. Query that node. Do **not** use
`adb screencap` / uiautomator to decide handler success.

1. This experiment uses a separate package and distribution port. Do not let
   the default `mob.connect` launcher restart the original probe. Set tunnels:
   `adb -s arc:5555 forward tcp:9200 tcp:9200` and
   `adb -s arc:5555 reverse tcp:4369 tcp:4369`.
2. Cookie `:mob_secret`; default node:

   ```text
   handbeam_probe_android_nativechat@127.0.0.1
   ```

   Bare `:"handbeam_probe_android@127.0.0.1"` often does not connect.
3. Use a unique host name, for example
   `elixir --name native_inspect@127.0.0.1 --cookie mob_secret ...`.

```elixir
node = :"handbeam_probe_android_nativechat@127.0.0.1"
Mob.Test.screen(node)          # HandbeamProbe.HomeScreen
Mob.Test.assigns(node)         # inspect page/chat, never dump credentials
:rpc.call(node, Process, :whereis, [HandbeamWeb.Endpoint])
# Native handler success requires assigns/transcript checks, not Endpoint alone.
```

Layer 2 (screenshots / MCP `dump_image`) only for layout or human evidence —
never to check assigns / seq. Layer 3 (`adb screencap`, raw uiautomator)
almost never.

Exit 0 from deploy/pack is not proof. `{:badrpc, :nodedown}` means the app
did not come up — stop. Dist is a debug tunnel, not a product feature.
Release builds (`MOB_RELEASE=1`) disable `-name` / cookie.

## Standard loop

Elixir-only iteration in this isolated package:

```text
edit → compile → RPC :code.load_binary → Mob.Test assigns/render checks
```

Hot-loaded code is temporary. Repack before claiming a persistent APK result.

Native / NIF / Kotlin / migration / first install on **ARC**:

```text
edit → mix mob.pack_apk --device arc:5555
     → force-stop + start MainActivity
     → explicit 9200/4369 tunnels above (never remove-all)
     → Mob.Test (prove native screen, handler state, transcript)
```

`mix mob.push` / `mix mob.deploy` on ARC is ephemeral or fails: kernel
disables `run-as`, so OTP never lands in `filesDir`.

## Android / ARC

Device: `arc:5555`, ABI `x86_64`, package `com.example.handbeam_probe.nativechat`.
Kotlin namespace remains `com.example.handbeam_probe`. Independent app data; do not
copy real keys from the original app. Loopback Endpoint is on 5088, Dist on 9200.

```sh
export JAVA_HOME=/home/hpbox/.local/share/mise/installs/java/temurin-17.0.18+8
export ANDROID_HOME=/home/hpbox/Android/Sdk
export PATH="/tmp/mob-bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:/usr/local/bin:$PATH"
mix mob.pack_apk --device arc:5555
adb -s arc:5555 shell am force-stop com.example.handbeam_probe.nativechat
adb -s arc:5555 shell am start -n com.example.handbeam_probe.nativechat/com.example.handbeam_probe.MainActivity
```

`/tmp/mob-bin` must precede PATH when host `arp` is missing. Java: Temurin 17.
Zig: pin in `.tool-versions`. Prefer `/usr/local/bin/mix` over mise shims —
the pin `elixir 1.20.0-otp-29` tries to install missing `erlang@29.0`.

One APK holds one OTP zip. ARC auto-detect is x86_64. A phone needs
`--abi arm64-v8a`. Do not install the ARC APK on ARM.

Local and CI pack through the same scripts (amd64 host may pack arm64 —
OTP tarballs are prebuilt; Zig/NDK cross-compile the native lib):

```sh
cd mobile
bash script/ci_setup_android.sh                   # local.properties + mob.exs from template
bash script/pack_android_apks.sh                  # both ABIs
bash script/pack_android_apks.sh --abi arm64-v8a  # phones
bash script/pack_android_apks.sh --abi x86_64 --skip-setup --skip-test
```

Outputs: `mobile/artifacts/Handbeam-<abi>.apk`. GitHub Actions:
`.github/workflows/android-apk.yml`.

ARC windows sometimes stay on `PlaceholderActivity`. Start `MainActivity`
explicitly. After install, force-stop then reopen so
`MobBridge.extractOtpIfNeeded()` unpacks the new zip.

DB: `Host.data_dir()/handbeam.db` (`filesDir`). Migrations via `Host.priv_dir()`,
never `Application.app_dir/2`. Do not start `:inets` / Ash.

Workspace paths are POSIX under `filesDir`. The in-app folder browser cannot
see `/sdcard/Download`. Adding a Downloads project uses the system SAF tree
picker, then copies into `filesDir/imported_workspaces/`. That copy is the
workspace; tools never read the tree URI. Downloads *root* is often not
grantable — pick a project subdirectory. Do not hardcode `/sdcard/Download`,
do not request all-files access, do not loosen PathValidator.

Foreground alive ≠ background alive. Switching apps freezes the BEAM unless
`AgentKeepAliveService` is running. Mob 0.7 has no `keep_alive` API. Copy is
the visible FGS from battery_timer: `specialUse`, `stopWithTask=false`,
`POST_NOTIFICATIONS`, `onCreate` → `startForeground` within 5s. Notification
is ongoing and silent; Stop → `nativeCancelRuns` (Runner.cancel) then
`stopSelf`. Activity `onDestroy` must not treat a still-running service as
process close.

A task is one Runner execution (`run_id`). `Handbeam.Runtime.TaskTracker`
reports running / waiting / ended. The FGS copy is silent status; completion
uses channel `handbeam_agent_ended` and a different notification id. App visible
means the Activity is started, not that LiveView is connected. Taps carry
`workspace_id` / `conversation_id` through `mob_notification_json` to
`HomeScreen`, which opens the native conversation after validating its workspace.

One agent drives the device. Inspection from others is fine; do not
concurrent-tap.

## Out of scope

Silent keep-alive, fake `mediaPlayback`, WorkManager-only OTP, store OTA,
public listen, battery NIFs. Ghostty NIFs are desktop/linux-gnu only — the
in-app terminal panel will not render VT on Android until a Bionic NIF exists.
