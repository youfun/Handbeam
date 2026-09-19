import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/handbeam start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :handbeam, HandbeamWeb.Endpoint, server: true
end

http_opts = [port: String.to_integer(System.get_env("PORT", "5002"))]

http_opts =
  if System.get_env("AMP_ORB") == "1" do
    Keyword.put(http_opts, :ip, {0, 0, 0, 0})
  else
    http_opts
  end

config :handbeam, HandbeamWeb.Endpoint, http: http_opts

config :handbeam,
  trust_project_code:
    String.downcase(System.get_env("HANDBEAM_TRUST_PROJECT_CODE", "false")) in ["1", "true", "yes"]

# ── OpenAI-compatible provider config ──
openai_base_url =
  System.get_env("OPENAI_BASE_URL") || "https://api.stepfun.com/step_plan/v1"

openai_model = System.get_env("OPENAI_MODEL") || "step-router-v1"

openai_max_tokens =
  case System.get_env("OPENAI_MAX_TOKENS") do
    nil -> nil
    v -> String.to_integer(v)
  end

openai_temperature =
  case System.get_env("OPENAI_TEMPERATURE") do
    nil -> nil
    v -> String.to_float(v)
  end

openai_config = [base_url: openai_base_url, model: openai_model]

openai_config =
  if openai_max_tokens,
    do: Keyword.put(openai_config, :max_tokens, openai_max_tokens),
    else: openai_config

openai_config =
  if openai_temperature,
    do: Keyword.put(openai_config, :temperature, openai_temperature),
    else: openai_config

config :handbeam, :openai, openai_config

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/handbeam/handbeam.db
      """

  config :handbeam, Handbeam.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :handbeam, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :handbeam, HandbeamWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind to localhost only — access via reverse proxy (nginx/Caddy).
      # Use {0, 0, 0, 0, 0, 0, 0, 0} to bind all interfaces (not recommended).
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :handbeam, HandbeamWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :handbeam, HandbeamWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
