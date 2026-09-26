# Reach architecture policy for Handbeam
# See https://github.com/elixir-vibe/reach for full reference
#
# Known accepted trade-offs:
#   agent ↔ pubsub cycle — PubSub.Session manages Agent.CandidateQueue directly.
#     Accepted: they run in the same BEAM process tree and share runtime state.
#     Session already holds queue_pid (Agent exposes it intentionally).

[
  # ── Architecture Layers ──
  layers: [
    web: "HandbeamWeb.*",

    # Runtime = Agent + Tool + PubSub, tightly coupled by design
    runtime: ["Handbeam.Agent.*", "Handbeam.Tool.*", "Handbeam.PubSub.*"],
    mcp: "Handbeam.MCP.*",
    memory: "Handbeam.Memory.*",
    delivery: "Handbeam.Delivery*",
    store: ["Handbeam.SessionStore*", "Handbeam.ConversationTranscriptStore*"],
    extension: "Handbeam.Extension.*",
    log: "Handbeam.Log.*",
    security: "Handbeam.Security.*",
    utils: "Handbeam.Utils*",
    mix_tasks: "Handbeam.Mix.Tasks.*",
    csv: ["Handbeam.Csv*", "Handbeam.CsvProfile*"],
    permissions: "Handbeam.Permissions*",
    settings: "Handbeam.Settings*",
    skills: "Handbeam.Skills*"
  ],

  # ── Dependency Rules ──
  deps: [
    forbidden: [
      # Core layers must NOT depend on web (web is a projection, not the owner)
      {:runtime, :web},
      {:memory, :web},
      {:mcp, :web},
      {:delivery, :web},
      {:security, :web},
      {:log, :web},

      # Delivery is outbound only — must not drive agent logic
      {:delivery, :runtime},

      # Memory should stay focused on storage, not runtime orchestration
      {:memory, :runtime}
    ]
  ],

  # ── Source Restrictions ──
  source: [
    forbidden_modules: []
  ],

  # ── Call Restrictions ──
  calls: [
    forbidden: [
      # Runtime must not do raw IO (use Logger instead)
      {"Handbeam.Agent.*", ["IO.puts", "IO.inspect"]},
      {"Handbeam.Tool.*", ["IO.puts", "IO.inspect"]},

      # Web layer must not touch database directly
      {"HandbeamWeb.*", ["Handbeam.Repo"]},

      # PubSub must not access database directly
      {"Handbeam.PubSub.*", "Handbeam.Repo"},

      # Delivery must not access database directly
      {"Handbeam.Delivery*", "Handbeam.Repo"}
    ]
  ],

  # ── Test Hints ──
  tests: [
    hints: [
      {"lib/handbeam/agent/**", ["test/handbeam/agent/*_test.exs"]},
      {"lib/handbeam/tool/**", ["test/handbeam/tool/*_test.exs"]},
      {"lib/handbeam/mcp/**", ["test/handbeam/mcp/*_test.exs"]},
      {"lib/handbeam_web/**", ["test/handbeam_web/*_test.exs"]}
    ]
  ]
]
