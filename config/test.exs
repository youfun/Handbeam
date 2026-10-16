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

# The app Clock must not claim rows while tests drive time themselves.
config :handbeam, :schedule_clock, enabled: false
config :handbeam, :schedule_dispatch, :sync
config :error_tracker, enabled: false

# Fix the test environment to use its own paths — never fall back to dev ~/.handbeam/... paths.
fixture_models_path = Path.expand("../test/fixtures/models.json", __DIR__)

# Give each test VM its own writable home, including workspace metadata.
# This must happen before application startup, not only in test_helper.exs.
test_data_dir =
  Path.join(
    System.tmp_dir!(),
    "handbeam_test_#{System.pid()}_#{System.unique_integer([:positive])}"
  )

test_workspace_path = Path.join(test_data_dir, ".handbeam/workspace")
System.put_env("HOME", test_data_dir)
System.put_env("HANDBEAM_MODELS_FILE", fixture_models_path)
System.put_env("HANDBEAM_WORKSPACES_FILE", Path.join(test_data_dir, ".handbeam/workspaces.json"))
File.mkdir_p!(test_workspace_path)

config :handbeam,
  models_file: fixture_models_path,
  workspaces_file: Path.join(test_data_dir, ".handbeam/workspaces.json"),
  workspace_root: test_workspace_path

config :phoenix_test, :endpoint, HandbeamWeb.Endpoint

config :handbeam,
  event_recorder_enabled?: false,
  session_store_enabled?: false,
  recover_transcripts: false,
  extension_hot_reload: false

config :handbeam, Handbeam.Gettext,
  default_locale: "en",
  locales: ~w(zh_CN en)
