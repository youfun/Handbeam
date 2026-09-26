defmodule Handbeam.Agent do
  @moduledoc """
  Agent entry point.

  Creates an agent configuration, initializes state, and runs the loop.

  ## Examples

      {:ok, state} = Handbeam.Agent.run("List the files", tools: [Handbeam.Tool.Builtin.Bash])
  """

  require Logger
  alias Handbeam.Agent.Config
  alias Handbeam.Agent.State
  alias Handbeam.Agent.Turn
  alias Handbeam.PubSub.Session

  @doc """
  Resume agent execution after tool approval decisions.

  Called by Runner when the user has made decisions on pending tool calls.
  Wraps `Turn.resume_after_tool_approval/3` with the same Session event
  callback and tool registration that `run/2` provides.

  ## Options
    - `:tools` - tool modules (inherited from original run opts)
    - `:session_id` - session id (required)
    - `:on_event` - event callback (overridden by session callback)
  """
  @spec resume_after_tool_approval(State.t(), [map()], keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def resume_after_tool_approval(%State{} = interrupted_state, decisions, opts) do
    # Register tools (same as run)
    working_dir = Keyword.get(opts, :working_directory)
    tools = Keyword.get(opts, :tools, default_tools())
    tools = maybe_append_beam_tools(tools, working_dir)
    Enum.each(tools, &Handbeam.Tool.Registry.register/1)

    if Handbeam.Terminal.available?() do
      Handbeam.Tool.Extension.Terminal.register()
    end

    opts = maybe_bootstrap_mcp(opts)

    interrupted_state =
      put_in(interrupted_state.config.context[:mcp_scope], opts[:context][:mcp_scope])

    # Re-wrap on_event with session broadcast (same pattern as run/2 but for resume)
    wrapped_opts =
      case Keyword.get(opts, :session_id) do
        nil ->
          opts

        session_id ->
          Keyword.put(
            opts,
            :on_event,
            session_event_callback(session_id, Keyword.get(opts, :on_event))
          )
      end

    result = Turn.resume_after_tool_approval(interrupted_state, decisions, wrapped_opts)
    {:ok, result}
  end

  @doc "Continue a run paused by the progress guard."
  def resume_after_stall_check(interrupted_state, decisions, opts) do
    opts = maybe_bootstrap_mcp(opts)

    wrapped_opts =
      case Keyword.get(opts, :session_id) do
        nil ->
          opts

        session_id ->
          Keyword.put(
            opts,
            :on_event,
            session_event_callback(session_id, Keyword.get(opts, :on_event))
          )
      end

    {:ok, Turn.resume_after_stall_check(interrupted_state, decisions, wrapped_opts)}
  end

  @doc """
  Run the agent with the given prompt and options.

  ## Options
    - `:tools` - list of tool modules (default: all built-in + memory tools)
    - `:model` - provider model string (default: configured in config)
    - `:system_prompt` - system prompt override
    - `:max_turns` - max agent loop iterations (default: 50)
    - `:working_directory` - file access root (default: cwd)
    - `:streaming` - enable streaming chunks (default: true)
    - `:on_chunk` - stream callback fn
    - `:on_event` - event callback fn
  """
  @spec run(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(prompt, opts \\ []) do
    # Register tools with the central registry.
    # Default: all built-in + memory tools.
    working_dir = Keyword.get(opts, :working_directory)
    tools = Keyword.get(opts, :tools, default_tools())
    tools = maybe_append_beam_tools(tools, working_dir)
    Enum.each(tools, &Handbeam.Tool.Registry.register/1)

    if Handbeam.Terminal.available?() do
      Handbeam.Tool.Extension.Terminal.register()
    end

    opts = maybe_bootstrap_mcp(opts)
    config = Config.from_opts(opts)

    {state, opts, session_id, queue_pid} =
      case Keyword.get(opts, :session_id) do
        nil ->
          {State.init(config, prompt) |> prepend_history(opts), opts, nil, nil}

        session_id ->
          {:ok, _pid} = Session.start_or_get(session_id: session_id, model: config.model)
          next_turn_messages = Session.drain_next_turn(session_id)

          {queue_pid, owns_queue?} =
            case Keyword.get(opts, :candidate_queue) do
              pid when is_pid(pid) ->
                {pid, false}

              nil ->
                {:ok, pid} =
                  Handbeam.Agent.CandidateQueue.start_link(session_id: session_id, owner: self())

                :ok = Session.attach_run(session_id, self(), pid)
                {pid, true}
            end

          state =
            config
            |> State.init(prompt)
            |> prepend_history(opts)
            |> prepend_messages(next_turn_messages)
            |> State.merge_run_metadata(%{
              session_id: session_id,
              conversation_id: Keyword.get(opts, :conversation_id, session_id)
            })

          opts =
            opts
            |> Keyword.put(:candidate_queue, queue_pid)
            |> Keyword.put(
              :on_event,
              session_event_callback(session_id, Keyword.get(opts, :on_event))
            )

          {state, opts, session_id, {queue_pid, owns_queue?}}
      end

    try do
      result = Turn.run_loop(state, opts)
      {:ok, result}
    after
      case queue_pid do
        {pid, true} when is_pid(pid) ->
          Handbeam.Agent.CandidateQueue.seal(pid)
          if session_id, do: Session.mark_run_finished(session_id)

        {_pid, false} ->
          :ok

        _ ->
          :ok
      end
    end
  end

  defp prepend_messages(%State{} = state, []), do: state

  defp prepend_messages(%State{} = state, messages) do
    %{state | messages: messages ++ state.messages}
  end

  defp prepend_history(%State{} = state, opts) do
    prepend_messages(state, Keyword.get(opts, :history_messages, []))
  end

  defp session_event_callback(session_id, nil) do
    fn {kind, payload} ->
      log_session_event(session_id, kind, payload)
      Session.broadcast_event(session_id, kind, payload)
    end
  end

  defp session_event_callback(session_id, user_on_event) when is_function(user_on_event, 1) do
    fn {kind, payload} = event ->
      log_session_event(session_id, kind, payload)
      user_on_event.(event)
      Session.broadcast_event(session_id, kind, payload)
    end
  end

  defp log_session_event(_session_id, :message_delta, %{chunk: chunk}) when is_binary(chunk) do
    :ok
  end

  defp log_session_event(_session_id, :thinking_delta, _payload) do
    :ok
  end

  defp log_session_event(session_id, kind, _payload) do
    require Logger

    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Agent] session callback #{kind} session=#{session_id}")
    end
  end

  # ── Default tool set ──

  @doc """
  Default tool modules for this BEAM.

  Assembled from `Handbeam.Host` capabilities, not from env sniffing. The list
  is owned by `Handbeam.Tool.Registry.host_tool_modules/0` (the same seed the
  registry uses at init); this is only the agent-facing name for it.
  """
  @spec default_tools() :: [module()]
  def default_tools, do: Handbeam.Tool.Registry.host_tool_modules()

  @doc """
  Tools for a workspace-independent chat.

  Memory, public page fetch, the in-app browser, opening a page in the system
  browser, and device calendar/alarm when the host has an artifact-delivery
  backend. File, shell, search, MCP, and skill tools stay off so a chat without
  a project root cannot fall through to the process working directory. Web and
  system-browser tools do not need workspace approval. Calendar and alarm still
  ask before they touch the device.
  """
  def free_chat_tools do
    base = [
      Handbeam.Tool.Builtin.WebFetch,
      Handbeam.Tool.Builtin.Browser,
      Handbeam.Tool.Builtin.OpenUrl,
      Handbeam.Tool.Memory.MemAssociate,
      Handbeam.Tool.Memory.MemLearn,
      Handbeam.Tool.Memory.MemRecall,
      Handbeam.Tool.Memory.MemReinforce
    ]

    if Handbeam.Host.artifact_delivery_backend() do
      base ++
        [
          Handbeam.Tool.Builtin.DeviceCalendar,
          Handbeam.Tool.Builtin.DeviceAlarm
        ]
    else
      base
    end
  end

  # ── BEAM tools auto-detection ──

  @beam_tools [
    Handbeam.Tool.Extension.Beam.Docs,
    Handbeam.Tool.Extension.Beam.Source,
    Handbeam.Tool.Extension.Beam.Sql
  ]

  @beam_eval_tool Handbeam.Tool.Extension.Beam.Eval

  defp maybe_append_beam_tools(tools, working_dir)
       when is_binary(working_dir) and working_dir != "" do
    tools ++ beam_tools_for_workspace(working_dir)
  end

  defp maybe_append_beam_tools(tools, _), do: tools

  defp beam_tools_for_workspace(working_dir) do
    config = Handbeam.WorkspaceSettings.beam_tools_config(working_dir)
    mix_project? = File.exists?(Path.join(working_dir, "mix.exs"))
    allow_eval? = Handbeam.Host.beam_eval?()

    auto_tools =
      if mix_project? and config.auto do
        @beam_tools
      else
        []
      end

    eval_tools =
      if allow_eval? and (config.eval or "ext__beam__eval" in config.explicit) do
        [@beam_eval_tool]
      else
        []
      end

    Enum.uniq(auto_tools ++ eval_tools)
  end

  defp maybe_bootstrap_mcp(opts) do
    mcp_opts = Handbeam.MCP.Access.options(opts)

    enabled? =
      case Keyword.fetch(opts, :mcp) do
        {:ok, value} -> value
        :error -> Handbeam.Host.mcp?() and Keyword.get(opts, :chat_scope) != :free
      end

    if enabled? do
      case Handbeam.MCP.bootstrap(mcp_opts) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(fn ->
            "MCP bootstrap failed (will retry on next run): #{inspect(reason)}"
          end)
      end
    end

    context = Keyword.get(opts, :context, %{})
    Keyword.put(opts, :context, Map.put(context, :mcp_scope, if(enabled?, do: mcp_opts)))
  end
end
