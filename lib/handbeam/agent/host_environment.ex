defmodule Handbeam.Agent.HostEnvironment do
  @moduledoc """
  Host facts shared by prompt composition and configuration inspection.
  An entry surface (Web/native/headless) never implies an execution platform.
  Section IDs and sources are safe to inspect; prompt bodies are not exported.
  """

  alias Handbeam.Host

  @doc "Selected environment sections. These describe capabilities, not tool authorization."
  def sections do
    [
      %{id: :workspace_files, source: :host_independent},
      %{id: if(Host.shell?(), do: :shell, else: :no_shell), source: :host_shell},
      %{id: :mix_project, source: :registry_unconditional_seed},
      %{id: browser_section(), source: :host_browser}
    ] ++
      if(Host.system_intents?(),
        do: [%{id: :host_scripts_and_intents, source: :host_system_intents}],
        else: []
      )
  end

  @doc "Compose a compact environment contract without inferring capabilities from the OS."
  def describe do
    "\n\n## Host execution environment\n\n" <>
      "These host capabilities do not grant permission. Use only tools exposed in this request. " <>
      "Web is an entry surface, not a Linux execution host. Do not infer desktop commands from an Android Linux kernel or iOS/Darwin architecture.\n\n" <>
      Enum.map_join(sections(), "\n\n", &text(&1.id))
  end

  defp browser_section do
    cond do
      Host.desktop_browser?() -> :desktop_browser
      Host.webview_browser?() -> :webview_browser
      true -> :no_browser
    end
  end

  defp text(:workspace_files) do
    "Read/edit/write, grep/file_search, and code_search operate on workspace files when exposed; paths remain subject to tool permissions. " <>
      "code_search returns path and line numbers. Without an embeddings config it matches symbols and tokens, not natural-language questions; a miss is not proof the code is absent. " <>
      git_backend_text()
  end

  defp text(:shell) do
    "The host permits the bash backend when exposed. Prefer file tools for file operations. " <>
      "This does not guarantee installed commands, a Linux environment, or a sandbox."
  end

  defp text(:no_shell) do
    "There is no Unix shell on this host available to the agent. Do not call `bash`, shell pipelines, or external mix/elixir commands. " <>
      "Use grep/file_search for exact or filename search, and code_search for symbol or configured semantic search. Browser availability is independent of shell access."
  end

  defp text(:mix_project) do
    "When exposed and its toolchain is available, `mix_project` manages a workspace mix.exs project: deps.get, compile, test and run. " <>
      "It executes on the host BEAM, not in a shell or sandbox. Only host-compatible pure Elixir/Erlang dependencies are supported; arbitrary NIFs and external builds are not supported."
  end

  defp text(:host_scripts_and_intents) do
    "For local computation, file processing or HTTP, use `run_elixir_script` when exposed: write the .exs first, then execute and verify outputs. " <>
      "It receives workspace and args bindings and runs high-privilege host BEAM code, not a shell or sandbox. " <>
      "When Mix is present, use Mix.install/2 at the top of the script for host-compatible pure Elixir/Erlang packages. " <>
      "Follow the script tool environment for Mix/Hex availability and curated APIs (Handbeam.Tool.ScriptEnvironment). " <>
      "System open/share tools launch native UI, not an agent browser session; configured callbacks do not guarantee a successful operation."
  end

  defp text(:desktop_browser),
    do:
      "The browser backend is agent-browser CLI when exposed; the executable and browser runtime must be installed. Browser access does not grant shell permission."

  defp text(:webview_browser),
    do:
      "The browser backend is a host WebView session when exposed, separate from system open/share UI. preview_serve registers workspace previews; it is not a shell server."

  defp text(:no_browser),
    do:
      "Neither desktop nor WebView browser capability is enabled by the host. Do not assume a browser is available."

  defp git_backend_text do
    cond do
      not is_nil(Host.get(:git_backend)) ->
        "The git tool uses the host-provided Git backend. Registration does not prove native dependencies are usable."

      Host.shell?() ->
        "Use `git` through bash for Git operations on this desktop host; there is no separate git tool."

      true ->
        "This host exposes neither bash nor a Git backend. Do not assume Git operations are available."
    end
  end
end
