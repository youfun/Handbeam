defmodule Handbeam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    case Handbeam.Agent.ModelConfig.ensure_config() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Handbeam] model config skipped: #{reason}")
    end

    children =
      [
        HandbeamWeb.Telemetry,
        Handbeam.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:handbeam, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:handbeam, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Handbeam.PubSub},
        {Registry, keys: :unique, name: Handbeam.SessionRegistry},
        {Registry, keys: :unique, name: Handbeam.AgentRunRegistry},
        {Registry, keys: :unique, name: Handbeam.AgentRunSupervisorRegistry},
        {Registry, keys: :unique, name: Handbeam.AgentRunQueueRegistry},
        Handbeam.Preview.Store,
        Handbeam.ExportSnapshot.Binding,
        Handbeam.Preview.Listener,
        Handbeam.Browser.Display,
        Handbeam.Tool.Registry,
        Handbeam.Workspace.MixOwner,
        Handbeam.Jobs.Cleaner,
        {DynamicSupervisor, name: Handbeam.Jobs.BeamSupervisor, strategy: :one_for_one},
        Handbeam.Jobs.Server,
        {Handbeam.Extension.Registry, name: Handbeam.Extension.Registry},
        Handbeam.Extension.Supervisor,
        Handbeam.Extension.Mount,
        {Handbeam.Extension.HotReloader,
         enabled: Application.get_env(:handbeam, :extension_hot_reload, true),
         trusted_project?: Handbeam.ProjectTrust.enabled?()}
      ] ++
        terminal_children() ++
        browser_children() ++
        [
          Handbeam.SessionSupervisor,
          Handbeam.AgentRunSupervisor,
          {Task.Supervisor, name: Handbeam.AgentRunTaskSupervisor},
          Handbeam.Agent.Delegation,
          Handbeam.Runtime.TaskTracker
        ] ++
        mcp_children() ++
        [HandbeamWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Handbeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HandbeamWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end

  defp terminal_children do
    if Handbeam.Host.terminal?() do
      [Handbeam.Terminal.Registry, Handbeam.Terminal.Supervisor]
    else
      []
    end
  end

  defp browser_children do
    desktop =
      if Handbeam.Host.desktop_browser?() do
        [Handbeam.Browser.Registry, Handbeam.Browser.Supervisor]
      else
        []
      end

    webview =
      if Handbeam.Host.webview_browser?() do
        [
          {Registry, keys: :unique, name: Handbeam.Browser.WebViewRegistry},
          Handbeam.Browser.WebViewSupervisor
        ]
      else
        []
      end

    desktop ++ webview
  end

  defp mcp_children do
    if Handbeam.Host.mcp?() do
      [Handbeam.MCP.RuntimeSupervisor, Handbeam.MCP, Handbeam.MCP.DeferredBootstrap]
    else
      []
    end
  end
end
