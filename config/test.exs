import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :handbeam, Handbeam.Repo,
  database: Path.expand("../handbeam_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :handbeam, HandbeamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # test-only, not a secret
  secret_key_base: "/BytCcxUvybaKIBsl3vksg1IngjTMcAYie8+ggR39G4ggiReaVsF6jKTpQrMt6+X",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Fix the test environment to use its own paths — never fall back to dev ~/.handbeam/... paths.
fixture_models_path = Path.expand("../test/fixtures/models.json", __DIR__)
fixture_workspace_path = Path.expand("../test/fixtures/workspace", __DIR__)
System.put_env("HANDBEAM_MODELS_FILE", fixture_models_path)
File.mkdir_p!(fixture_workspace_path)

config :handbeam,
  models_file: fixture_models_path,
  workspace_root: fixture_workspace_path

config :phoenix_test, :endpoint, HandbeamWeb.Endpoint

config :handbeam,
  event_recorder_enabled?: false,
  session_store_enabled?: false,
  extension_hot_reload: false

config :handbeam, HandbeamWeb.Gettext,
  default_locale: "en",
  locales: ~w(zh_CN en)
