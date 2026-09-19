import Config

# 本地工具，关闭 check_origin 以允许局域网访问
config :handbeam, HandbeamWeb.Endpoint,
  check_origin: false,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
