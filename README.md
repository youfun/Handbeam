# Handbeam

[English](README.md) · [中文](README.zh.md)

A local agent assistant. Chat, tools, and memory stay on the machine. One OTP runtime is shared by [LiveView](lib/handbeam_web/live) and [mobile](mobile/) (Android + iOS).

- Read, edit, and write files; run a shell; fuzzy-search files; locate code by symbol or configured embeddings (`code_search` returns paths and line numbers, then `read` loads the file)
- Workspace permissions (auto / prompt / deny)
- Streaming replies and tool status
- Anthropic and OpenAI-compatible APIs (StepFun, DeepSeek, OpenRouter, and others)
- MCP, BEAM introspection, and memory across sessions
- Same Coordinator / Runner on Android and iOS

## App screenshot

Native Android chat interface, captured on a physical device in English.

<img src="docs/screenshots/android-chat-en.png" alt="Handbeam Android chat screen in English" width="360">

### On-device Elixir projects (experimental)

On a phone, chat with the agent to create, edit, and run Elixir/Mix projects in the workspace. Mix can fetch deps, compile, test, and run through `mix_project` on the app's bundled Elixir/OTP. No extra Linux environment.

- Pure Elixir/Erlang deps that match the host version are supported. Unsupported native builds, extra toolchains, and host-version conflicts are rejected.
- Project code runs in the app's BEAM VM. This is not a separate VM or a security sandbox. Only run code you trust.
- Chat-driven end-to-end runs have been verified on a physical Android device. iOS has only been verified in the simulator, not on a device or a full release build.

Requires Elixir 1.20, OTP 28+, and Node.

## Web UI packages

GitHub Releases tag `web-latest` (and `v*` tags) includes a self-contained OTP package. Unpack it and start the Web UI without installing Elixir:

- `handbeam-web-linux-x86_64.tar.gz`
- `handbeam-web-windows-amd64.zip`
- `handbeam-web-windows-amd64-toolchain.zip` (experimental)
- `handbeam-web-macos-arm64.tar.gz`
- `Handbeam-macos-arm64.zip` (native WebKit app)

Open `Handbeam.app` from the native macOS zip. For the Web UI packages, run `./start.sh` on Linux and macOS or `start.bat` on Windows. The default URL is `http://localhost:5008`. The native macOS shell uses system WebKit, not Electron. Windows packages do not include the in-browser terminal; Ghostty has no Windows NIF. The toolchain zip adds Elixir, Mix, Hex, Rebar3, and MinGit to PATH for that process only. It does not include a C compiler. Windows ARM64 is not published.

## Inspect effective host configuration

`mix handbeam.inspect_config --workspace /path/to/workspace` prints a redacted
JSON report without starting Handbeam, initializing stores, resolving credentials
or bootstrapping MCP. It loads normal Mix configuration and compiles when needed;
it inspects this Mix VM, **not** an already running phone or Web session. Inside
an existing host, use `Handbeam.ConfigInspection.report(workspace: path)`.

The report separates Host seed decisions, observed registry membership, passive
dependency checks, and unknown run authorization/model visibility. It explains
Host defaults/overrides (including browser precedence), effective Model/AI field
sources, workspace approval defaults, and injected environment section IDs.
Global settings override defaults; normalized workspace settings override global
settings. Runtime provider environment overrides apply above catalog values;
entry-point model selection and per-run options are not reconstructed. Approval
defaults are not per-call decisions: arguments, session overrides and capability
rules still apply. `unknown` is intentional, not a claim of availability.

For safe sharing, arbitrary strings are withheld: paths, model IDs, permission
patterns, dynamic tool names, URLs, credentials and prompt bodies. Sources identify
the owning layer, not the original writer of an Application environment value.
No executable, native callback, browser or network availability probe is run.
Desktop/Web/native/headless share the same runtime. Default and custom agent
prompts append the same Host-derived environment contract; Android/iOS have no
agent shell when Host disables it. Script API details remain in ScriptEnvironment,
not duplicated platform-specific prompts. Later runtime hooks can still transform
the outgoing prompt, which this report does not evaluate.

## Run

```bash
cp models.example.json models.json   # set apiKey, or use env:OPENAI_API_KEY
mix setup
mix phx.server                       # http://localhost:5002
```

Pick a workspace and chat. CSS and JavaScript sources live in `assets/`; generated
files in `priv/static/assets/` are not committed. The original styles are preserved
in `assets/css/`, with the prebuilt baseline stylesheet in `assets/default.css`.

`mix setup` installs dependencies and builds assets. For assets alone, use
`mix assets.setup` then `mix assets.build`. `mix phx.server` watches CSS and JS
sources and rebuilds them automatically. Release builds use `mix assets.deploy`
to minify assets and generate Phoenix digests. `mix compile` only compiles Elixir.

```bash
mix test --exclude slow --exclude e2e
```

## ChatGPT / Codex subscription

In Web Settings → Available models → Subscription login, select **ChatGPT (Codex subscription)**.
Enter the device code on OpenAI's verification page, then select a model from this provider.
Use the refresh-subscription-models button to update the catalog. If device login is unavailable,
check whether your account permits it. The native mobile settings UI does not yet offer this login.

No Codex CLI is required. Inference uses the Codex Responses backend; Handbeam still owns tools
and approvals. This uses ChatGPT Codex entitlements, not Platform API credits. Model availability,
limits and additional usage depend on your account. There is no automatic API-key billing fallback,
and unknown cost is not displayed as free. Backend compatibility may change with official clients.
Credentials are stored in `~/.handbeam/auth.json` (0600); never share or commit that file.

## Private Git repositories

The `git` tool accepts a credential name (`credential`), never a password or PAT.
Configure credentials in the trusted host at startup, not in agent-editable
workspace settings or chat. For example, in the host's runtime configuration:

```elixir
config :handbeam, :git_credentials, %{
  "project-origin" => [
    endpoint: "https://github.com",
    password: System.fetch_env!("PROJECT_GIT_TOKEN")
  ]
}
```

The tool call uses `{"action":"push","credential":"project-origin"}`.
Fresh authentication challenges must match the configured HTTPS endpoint.
libgit2 rejects cross-host redirects and HTTPS downgrades, but may reuse credentials
on other HTTPS ports or paths of the same hostname. **Configuration trusts all HTTPS
services on that hostname: it does not provide port or repository-path isolation.**
Do not configure credentials for hosts containing untrusted services. Use a
least-privilege, repository-scoped PAT as well.
Omit `credential` for anonymous access. Mobile hosts can inject the same startup
configuration; there is no new credential-management UI. Previously exposed
secrets are not removed from old conversations automatically; revoke and rotate them.

## Mobile (Android + iOS)

```bash
cd mobile
mix deps.get
mix test
bash script/pack_android_apks.sh --abi arm64-v8a   # Android
mix ios.native                                     # iOS Simulator (Xcode)
```

See [`mobile/README.md`](mobile/README.md). On ChromeOS use `--abi x86_64`.
iOS bundle id is `com.example.handbeam_probe`; the simulator Dist node is
`handbeam_probe_ios_<first-8-udid>@127.0.0.1`.

## License

[AGPL-3.0](LICENSE). Copyright (C) 2026 youfun.
