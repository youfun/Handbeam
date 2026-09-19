# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :handbeam,
  ecto_repos: [Handbeam.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :handbeam, HandbeamWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HandbeamWeb.ErrorHTML, json: HandbeamWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Handbeam.PubSub,
  live_view: [signing_salt: "Wkzn+39Y"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Erlang/OTP's built-in JSON implementation through Handbeam's Phoenix adapter.
config :phoenix, :json_library, Handbeam.JSON

# ── Gettext i18n 配置 ──
config :handbeam, HandbeamWeb.Gettext,
  default_locale: "zh_CN",
  locales: ~w(zh_CN en)

# ── HTTP client (Req/Finch): force HTTP/1.1 to avoid Finch pool hang ──
#
# Finch defaults to HTTP/2 which multiplexes requests over a single TCP
# connection. With long-lived connections to LLM providers (Anthropic,
# StepFun, OpenAI), HTTP/2 stream multiplexing can cause pool hangs when
# one stream stalls — blocking all other requests sharing the same pool.
#
# HTTP/1.1 uses one connection per request from the pool, so a stalled
# request only blocks its own connection. Other requests proceed normally.
#
# See: https://github.com/sneako/finch/issues/224
config :req, finch_options: [conn_opts: [protocols: [:http1]]]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
