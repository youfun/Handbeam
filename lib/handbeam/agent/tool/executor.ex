defmodule Handbeam.Agent.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Uses `Handbeam.Agent.Tool.Result` for dual-channel content/details separation
  and `Handbeam.Utils.Truncate` for consistent output truncation.

  Supports parallel execution via Task.async_stream.
  """

  alias Handbeam.Agent.{Message, State}
  alias Handbeam.Agent.Tool.Result

  require Logger

  @default_max_result_chars 50_000

  @doc """
  Execute all tool calls and return a result message or halt signal.

  Tool results are wrapped in `ToolResult`, truncated consistently,
  and mapped to provider-compatible `tool_result_block` maps.
  UI details (exit_code, timed_out, file metadata, etc.) are preserved
  in the `"details"` key of each block and are not sent to the LLM.

  This is the main entry point used by the agent Turn loop.
  Internally calls `execute_all_with_details/2` and returns only the
  stripped result message.
  """
  @spec execute_all([map()], State.t()) :: {:ok, Message.t()}
  def execute_all(tool_calls, %State{} = state) do
    {:ok, result_msg, _ui_blocks} = execute_all_with_details(tool_calls, state)
    {:ok, result_msg}
  end

  @doc """
  Execute all tool calls and return both the stripped LLM-facing result
  and the unstripped UI blocks.

  Returns `{:ok, result_msg, ui_blocks}` where:
    - `result_msg` is a `Message.tool_results` with `"details"` stripped
    - `ui_blocks` is the list of pre-strip blocks that still contain
      `"details"` (exit_code, file_path, bytes, lines, etc.)

  The caller (Turn) appends `result_msg` to state history and broadcasts
  `ui_blocks` details to the UI via PubSub tool_end events.
  """
  @spec execute_all_with_details([map()], State.t()) :: {:ok, Message.t(), [map()]}
  def execute_all_with_details(tool_calls, %State{} = state) do
    context = build_context(state)

    tool_fns =
      Handbeam.Tool.Registry.tool_fns()
      |> Map.take(authorized_tools(state.config))

    {sequential, concurrent} = partition_by_concurrency(tool_calls, tool_fns)
    tool_timeout = state.config.tool_timeout

    Logger.debug(
      "[Executor] dispatch sequential=#{length(sequential)} concurrent=#{length(concurrent)} " <>
        "timeout_ms=#{tool_timeout}"
    )

    # Phase 1: Sequential tools — each wrapped in a supervised task so a hung
    # tool cannot deadlock the entire Turn. Mirrors the concurrent path's
    # timeout protection but preserves strict sequential ordering.
    seq_results =
      Enum.map(sequential, fn call ->
        execute_one_with_timeout(call, tool_fns, context, tool_timeout)
      end)

    # Phase 2: Concurrent tools
    par_results =
      if concurrent == [] do
        []
      else
        concurrent
        |> Task.async_stream(
          &execute_one(&1, tool_fns, context),
          timeout: tool_timeout,
          ordered: true,
          on_timeout: :kill_task
        )
        |> Enum.with_index()
        |> Enum.map(fn
          {{:ok, result}, _idx} ->
            result

          {{:exit, reason}, idx} ->
            tc = Enum.at(concurrent, idx)
            tool_id = (tc && (tc[:id] || tc["id"] || Map.get(tc, :id))) || "unknown"
            tool_name = (tc && (tc[:name] || tc["name"])) || "unknown"

            Logger.warning(fn ->
              "[Executor] concurrent tool timeout/exit tool=#{tool_name} id=#{tool_id} " <>
                "reason=#{inspect(reason)}"
            end)

            result_to_block(Result.error("Tool execution timed out"), tool_id)
        end)
      end

    # Reassemble in original order (pre-strip blocks with details intact)
    ui_blocks =
      reassemble_ordered(tool_calls, sequential, seq_results, concurrent, par_results)

    # Strip details for LLM-friendly message
    results = Enum.map(ui_blocks, &strip_details/1)

    {:ok, Message.tool_results(results), ui_blocks}
  end

  @doc """
  Strip the `:details` key from a tool_result block.

  Details (exit_code, timed_out, file metadata, etc.) are preserved
  for UI via PubSub tool_end events, but must NOT be stored in
  conversation history or sent to the LLM.
  """
  def strip_details(block) when is_map(block) do
    Map.delete(block, :details)
  end

  defp execute_one(%{name: name, input: input, id: id}, tool_fns, context) do
    name = normalize_tool_name(name)
    t0 = System.monotonic_time(:millisecond)
    Logger.debug("[Executor] start tool=#{name} id=#{id}")

    authorized = name in authorized_tools(context.delegation_config)

    result =
      case if(authorized, do: fetch_tool(tool_fns, name), else: :error) do
        {:ok, entry} ->
          try do
            case entry.executor.(input || %{}, Map.put(context, :tool_call_id, id)) do
              {:ok, text} ->
                Result.new(text)

              {:ok, text, data} ->
                Result.new(text, data)

              {:error, reason, details} when is_map(details) ->
                Result.error(reason, details)

              {:error, reason} ->
                Result.error(reason)
            end
          rescue
            e ->
              msg = "Tool #{name} crashed: #{Exception.message(e)}"
              Logger.warning(fn -> msg <> "\n" <> Exception.format(:error, e, __STACKTRACE__) end)
              Result.error(msg)
          end

        :error ->
          msg = "Unknown tool: #{name}"
          Logger.warning(fn -> msg end)

          dev_log(
            "[Executor] unknown tool call raw=#{inspect(%{id: id, name: name, input: input})}"
          )

          Result.error(msg)
      end

    max_chars = get_max_result_chars(tool_fns, name)
    truncated = truncate_result(result, max_chars)
    duration_ms = System.monotonic_time(:millisecond) - t0

    Logger.debug(
      "[Executor] end tool=#{name} id=#{id} duration_ms=#{duration_ms} " <>
        "is_error=#{truncated.is_error}"
    )

    result_to_block(truncated, id)
  end

  # Run a sequential tool inside a supervised Task and enforce timeout so a
  # hung tool (e.g. a bash subprocess that never EOFs on its port) cannot
  # block the whole Turn forever.
  defp execute_one_with_timeout(call, tool_fns, context, timeout_ms) do
    tool_id = (call && (call[:id] || call["id"] || Map.get(call, :id))) || "unknown"
    tool_name = (call && (call[:name] || call["name"])) || "unknown"

    start_task = if context.delegation_config.delegated?, do: :async, else: :async_nolink

    task =
      apply(Task.Supervisor, start_task, [
        Handbeam.AgentRunTaskSupervisor,
        fn ->
          execute_one(call, tool_fns, context)
        end
      ])

    # Outer guard: tool-specific timeout + small grace period for kill/cleanup.
    guard_ms = timeout_ms + 5_000

    case Task.yield(task, guard_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning(fn ->
          "[Executor] sequential tool exited tool=#{tool_name} id=#{tool_id} " <>
            "reason=#{inspect(reason)}"
        end)

        result_to_block(Result.error("Tool execution failed: #{inspect(reason)}"), tool_id)

      nil ->
        Logger.warning(fn ->
          "[Executor] sequential tool timeout tool=#{tool_name} id=#{tool_id} " <>
            "timeout_ms=#{guard_ms}"
        end)

        result_to_block(
          Result.error("Tool execution timed out after #{div(guard_ms, 1000)}s"),
          tool_id
        )
    end
  end

  defp fetch_tool(_tool_fns, nil), do: :error
  defp fetch_tool(_tool_fns, ""), do: :error
  defp fetch_tool(tool_fns, name), do: Map.fetch(tool_fns, name)

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  defp normalize_tool_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_tool_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_tool_name(name), do: name

  defp get_max_result_chars(tool_fns, name) do
    case Map.fetch(tool_fns, name) do
      {:ok, entry} ->
        case entry.max_result_chars do
          :unlimited -> nil
          max when is_integer(max) -> max
          _ -> @default_max_result_chars
        end

      _ ->
        @default_max_result_chars
    end
  end

  @doc """
  Apply truncation to a ToolResult's content using a unified strategy.

  Uses `head_tail` strategy to preserve both beginning and end of output.
  The original content is preserved in result.details when truncation occurs.
  """
  def truncate_result(%Result{is_error: true} = result, _max_chars), do: result

  def truncate_result(%Result{content: content} = result, max_chars)
      when is_integer(max_chars) and byte_size(content) > max_chars do
    trunc_result = Handbeam.Utils.Truncate.truncate_head_tail(content, max_bytes: max_chars)

    %Result{
      result
      | content: trunc_result.content,
        details: Map.put(result.details || %{}, :original_content, content)
    }
  end

  def truncate_result(result, _max_chars), do: result

  @doc """
  Convert a ToolResult to a provider-facing tool_result_block map.

  The `"details"` key carries UI metadata (exit_code, timed_out, file_path, etc.)
  and is NOT sent to the LLM — providers only look at `"content"` and `"is_error"`.
  """
  def result_to_block(%Result{} = result, tool_use_id) do
    case result do
      %{is_error: true} ->
        Message.tool_result_block(tool_use_id, result.content, true, result.details)

      %{details: nil} ->
        Message.tool_result_block(tool_use_id, result.content, false)

      _ ->
        Message.tool_result_block(tool_use_id, result.content, false, result.details)
    end
  end

  defp partition_by_concurrency(tool_calls, tool_fns) do
    Enum.split_with(tool_calls, fn call ->
      case Map.fetch(tool_fns, call[:name]) do
        {:ok, entry} -> entry.concurrent? == false
        :error -> false
      end
    end)
  end

  defp reassemble_ordered(tool_calls, seq_calls, seq_results, par_calls, par_results) do
    seq_map = Map.new(Enum.zip(seq_calls, seq_results))
    par_map = Map.new(Enum.zip(par_calls, par_results))
    Enum.map(tool_calls, fn call -> Map.get(seq_map, call) || Map.get(par_map, call) end)
  end

  @doc "The run's authorization ceiling, intersected with the live session policy."
  def authorized_tools(config) do
    registered = Map.keys(Handbeam.Tool.Registry.tool_fns())
    session_id = config.context[:conversation_id] || config.context[:session_id]
    active = if session_id, do: Handbeam.Tool.Registry.active_for_session(session_id)
    parent = config.context[:delegation_parent]

    parent_active =
      if parent, do: Handbeam.Tool.Registry.active_for_session(parent.conversation_id)

    registered
    |> Enum.filter(&(is_nil(config.allowed_tools) or &1 in config.allowed_tools))
    |> Enum.filter(&(is_nil(active) or &1 in active))
    |> Enum.filter(&(is_nil(parent_active) or &1 in parent_active))
    |> Enum.filter(fn _ ->
      is_nil(parent) or Handbeam.Agent.Delegation.Policy.live_parent?(parent)
    end)
  end

  defp build_context(%State{
         config: config,
         run_metadata: run_metadata,
         usage: usage,
         tool_guard_overrides: overrides
       }) do
    context = config.context || %{}
    metadata = run_metadata || %{}

    context
    |> Map.merge(%{
      working_directory: config.working_directory,
      skill_paths: config.skill_paths,
      tool_timeout: config.tool_timeout,
      run_id: config.run_id,
      runner_pid: config.runner_pid,
      delegation_config: config,
      parent_usage: usage,
      authorized_tools:
        Enum.reject(authorized_tools(config), fn name ->
          mode = Map.get(overrides || %{}, name, :auto)
          mode not in [:auto, "auto"]
        end),
      conversation_id:
        Map.get(context, :conversation_id) || Map.get(metadata, :conversation_id) ||
          Map.get(metadata, :session_id),
      session_id: Map.get(metadata, :session_id) || Map.get(context, :session_id),
      workspace_id: Map.get(context, :workspace_id)
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
