# Handbeam

[English](README.md) · [中文](README.zh.md)

A local agent assistant. Chat, tools, and memory stay on the machine. One OTP runtime is shared by [LiveView](lib/handbeam_web/live) and [mobile](mobile/) (Android + iOS).

- Read, edit, and write files; run a shell; fuzzy-search files
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
