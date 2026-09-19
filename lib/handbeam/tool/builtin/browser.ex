defmodule Handbeam.Tool.Builtin.Browser do
  @moduledoc """
  Native browser tool.

  Desktop Mix keeps the `args` + `agent-browser` schema.
  Android / ARC (`webview_browser: true`, `desktop_browser: false`)
  uses a narrow `action` schema against an independent WebView session.
  """

  @behaviour Handbeam.Agent.Tool

  alias Handbeam.Browser.{Cli, Policy, Result, Session, WebViewSession, WebViewSupervisor}
  alias Handbeam.Settings

  @mobile_actions ~w(open snapshot eval click fill back show hide close)

  @impl true
  def name, do: "browser"

  @impl true
  def description do
    if Handbeam.Host.webview_browser?() do
      "Drive the on-device Agent WebView. Pass action (open, snapshot, eval, " <>
        "click, fill, back, show, hide, close). This is not the system browser. " <>
        "Use android_open_url when the user should leave Handbeam and open http(s) " <>
        "in Chrome or another installed browser."
    else
      "Drive a real browser for web research, reading live docs, clicking, " <>
        "filling forms, taking screenshots, and extracting page content. " <>
        "Pass CLI args after agent-browser (for example open, snapshot -i, click @eN). " <>
        "Do not include --json or the binary name."
    end
  end

  @impl true
  def input_schema do
    if Handbeam.Host.webview_browser?() do
      mobile_schema()
    else
      desktop_schema()
    end
  end

  @impl true
  def max_result_chars, do: 50_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    if webview_backend?(context, input) do
      execute_webview(input, context)
    else
      execute_desktop(input, context)
    end
  end

  def execute(_input, _context), do: {:error, "invalid browser input"}

  defp webview_backend?(context, input) do
    cond do
      context[:browser_backend] == :webview -> true
      Handbeam.Host.webview_browser?() -> true
      is_function(context[:browser_webview_runner], 2) -> true
      field(input, "action") && is_nil(field(input, "args")) -> true
      true -> false
    end
  end

  defp execute_desktop(input, context) do
    with {:ok, args} <- fetch_args(input),
         {:ok, timeout_ms} <- fetch_timeout(input),
         {:ok, session_mode} <- fetch_session_mode(input),
         :ok <- reject_denied(args) do
      run_cli(args, timeout_ms, session_mode, context)
    end
  end

  defp execute_webview(input, context) do
    with {:ok, action} <- fetch_action(input),
         {:ok, session_mode} <- fetch_session_mode(input),
         {:ok, timeout_ms} <- fetch_timeout(input, 20_000),
         :ok <- maybe_reject_url(action, input) do
      run_webview(action, input, session_mode, timeout_ms, context)
    end
  end

  defp run_webview(action, input, session_mode, timeout_ms, context) do
    conversation_id = context[:conversation_id] || context["conversation_id"] || "anon"

    command = %{
      action: action,
      url: field(input, "url"),
      js: field(input, "js"),
      ref: field(input, "ref"),
      value: field(input, "value") || field(input, "text"),
      reason: field(input, "reason"),
      takeover: field(input, "takeover"),
      refs_gen: field(input, "refs_gen")
    }

    cond do
      is_function(context[:browser_webview_runner], 2) ->
        wrap_webview(context[:browser_webview_runner].(command, timeout_ms: timeout_ms))

      WebViewSupervisor.running?() ->
        with {:ok, %{session_id: session_id}} <-
               WebViewSupervisor.ensure(conversation_id, session_mode,
                 workspace_id: context[:workspace_id]
               ) do
          WebViewSession.call(session_id, command, timeout_ms: timeout_ms)
        end

      true ->
        {:error, "on-device browser host is not configured"}
    end
  end

  defp wrap_webview({:ok, text}) when is_binary(text) do
    {:ok, text, %{backend: "webview"}}
  end

  defp wrap_webview({:ok, text, details}) when is_binary(text) and is_map(details) do
    {:ok, text, Map.put_new(details, :backend, "webview")}
  end

  defp wrap_webview({:error, reason, details}) when is_binary(reason) and is_map(details) do
    {:error, reason, Map.put_new(details, :backend, "webview")}
  end

  defp wrap_webview({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp wrap_webview({:error, reason}), do: {:error, inspect(reason)}
  defp wrap_webview(other), do: {:error, inspect(other)}

  defp maybe_reject_url("open", input) do
    case field(input, "url") do
      url when is_binary(url) ->
        uri = URI.parse(url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          :ok
        else
          {:error, "only http(s) URLs are allowed"}
        end

      _ ->
        {:error, "url is required"}
    end
  end

  defp maybe_reject_url(_action, _input), do: :ok

  defp fetch_action(input) do
    case field(input, "action") do
      action when action in @mobile_actions -> {:ok, action}
      nil -> {:error, "action is required"}
      other -> {:error, "unsupported browser action: #{other}"}
    end
  end

  defp run_cli(args, timeout_ms, session_mode, context) do
    case Cli.run(args, cli_opts(args, timeout_ms, session_mode, context)) do
      {:ok, raw} ->
        raw
        |> Result.parse(artifact_dir: artifact_dir(context))
        |> wrap_parsed()

      {:error, :missing_binary, binary} ->
        parsed = Result.missing_binary(binary)
        {:error, parsed.content, parsed.details}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp wrap_parsed(%{details: %{result_category: "failure"}} = parsed) do
    {:error, parsed.content, parsed.details}
  end

  defp wrap_parsed(parsed) do
    {:ok, parsed.content, parsed.details}
  end

  defp reject_denied(args) do
    case Policy.classify(args) do
      {:deny, meta} -> {:error, meta[:reason] || "Browser command denied"}
      _ -> :ok
    end
  end

  defp fetch_args(%{"args" => args}) when is_list(args), do: {:ok, args}
  defp fetch_args(%{args: args}) when is_list(args), do: {:ok, args}
  defp fetch_args(_), do: {:error, "args is required"}

  defp fetch_timeout(input, default \\ 35_000) do
    case field(input, "timeout_ms") do
      nil ->
        {:ok, default}

      value when is_integer(value) and value >= 1 and value <= 300_000 ->
        {:ok, value}

      _ ->
        {:error, "timeout_ms must be an integer between 1 and 300000"}
    end
  end

  defp fetch_session_mode(input) do
    case field(input, "session_mode") || "auto" do
      mode when mode in ["auto", "fresh"] -> {:ok, mode}
      _ -> {:error, "session_mode must be auto or fresh"}
    end
  end

  defp cli_opts(args, timeout_ms, session_mode, context) do
    dir = artifact_dir(context)

    [
      timeout_ms: timeout_ms,
      session_name: session_name(args, session_mode, context),
      screenshot_dir: dir
    ]
    |> maybe_put(:runner, context[:browser_runner])
    |> maybe_put(:executable, context[:browser_executable])
    |> maybe_put(:find_executable, context[:browser_find_executable])
  end

  defp session_name(args, session_mode, context) do
    cond do
      Policy.inspection?(args) ->
        nil

      is_binary(context[:browser_session_name]) ->
        context[:browser_session_name]

      is_binary(context[:conversation_id]) ->
        case Session.ensure(context[:conversation_id], session_mode,
               workspace_id: context[:workspace_id],
               closer: context[:browser_session_closer]
             ) do
          {:ok, %{name: name}} -> name
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp artifact_dir(context) do
    id = context[:conversation_id] || "anon"
    Path.join([Settings.default_global_dir(), "browser", id])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, field_atom(key))
  end

  defp field_atom("args"), do: :args
  defp field_atom("action"), do: :action
  defp field_atom("url"), do: :url
  defp field_atom("js"), do: :js
  defp field_atom("ref"), do: :ref
  defp field_atom("value"), do: :value
  defp field_atom("text"), do: :text
  defp field_atom("reason"), do: :reason
  defp field_atom("takeover"), do: :takeover
  defp field_atom("refs_gen"), do: :refs_gen
  defp field_atom("timeout_ms"), do: :timeout_ms
  defp field_atom("session_mode"), do: :session_mode
  defp field_atom(_), do: nil

  defp desktop_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["args"],
      properties: %{
        args: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Arguments passed after agent-browser. Do not include --json or the binary name."
        },
        timeout_ms: %{
          type: "integer",
          minimum: 1,
          maximum: 300_000,
          description: "Per-call subprocess watchdog in milliseconds."
        },
        session_mode: %{
          type: "string",
          enum: ["auto", "fresh"],
          default: "auto",
          description: "auto reuses this conversation's browser; fresh starts a new one."
        }
      }
    }
  end

  defp mobile_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: %{
        action: %{
          type: "string",
          enum: @mobile_actions,
          description: "Browser command against this conversation's independent WebView session."
        },
        url: %{type: "string", description: "http(s) URL for open."},
        js: %{type: "string", description: "JavaScript for eval. Result is an ordinary string."},
        ref: %{type: "string", description: "data-handbeam-ref from the last snapshot."},
        value: %{type: "string", description: "Value for fill."},
        text: %{type: "string", description: "Alias for fill value."},
        reason: %{type: "string", description: "Human-visible reason when requesting takeover."},
        takeover: %{type: "boolean", description: "If true, show asks the user to take control."},
        refs_gen: %{type: "integer", description: "Snapshot generation; stale refs are rejected."},
        timeout_ms: %{
          type: "integer",
          minimum: 1,
          maximum: 300_000,
          description: "Per-call wait in milliseconds."
        },
        session_mode: %{
          type: "string",
          enum: ["auto", "fresh"],
          default: "auto",
          description:
            "auto reuses this conversation's WebView; fresh rebuilds the page and generation. Shared profile cookies are not cleared."
        }
      }
    }
  end
end
