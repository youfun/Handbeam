defmodule Handbeam.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Handbeam.Agent.{Compactor, Message, Reasoning, State}
  alias Handbeam.Agent.Middleware
  alias Handbeam.Agent.Provider.Retry
  alias Handbeam.Agent.Tool.Executor
  alias Handbeam.Extension.HookPipeline

  require Logger

  @max_tool_event_output 16_000
  @final_turn_prompt """
  You have reached the final agent step. Do not call tools. Give the user the best complete answer you can now. Summarize completed work, verification, unresolved items, and the next concrete action when anything remains.
  """

  @doc """
  Resume agent loop from an interrupted tool-approval state.

  Called by `Handbeam.Agent.resume_after_tool_approval/3` after the user has
  made approval decisions on pending tool calls. Does NOT re-request the
  provider — instead executes the approved tool batch and continues the
  normal agent loop.

  ## Decisions format

  Each decision is a map:

      %{
        "tool_call_id" => "call_xxx",
        "tool_name" => "bash",
        "action" => "approve" | "deny",
        "remember" => true | false
      }
  """
  @spec resume_after_tool_approval(State.t(), [map()], keyword()) :: State.t()
  def resume_after_tool_approval(%State{status: :interrupted} = state, decisions, opts) do
    interrupt_data = state.interrupt_data || %{}
    hitl_ids = interrupt_id_list(interrupt_data, :hitl_tool_call_ids, "hitl_tool_call_ids")

    _auto_ids =
      interrupt_id_list(
        interrupt_data,
        :auto_approved_tool_call_ids,
        "auto_approved_tool_call_ids"
      )

    tool_calls = last_tool_calls_from_state(state)
    decision_by_id = decision_lookup(decisions)

    {_denied_calls, denied_blocks, remembered_overrides, denied_ids} =
      partition_hitl_decisions(hitl_ids, tool_calls, decision_by_id)

    approved_calls = calls_not_denied(tool_calls, denied_ids)
    state = apply_approval_resume_state(state, denied_blocks, remembered_overrides)

    state
    |> continue_after_approval(approved_calls, denied_blocks, opts)
    |> finish_run(opts)
  end

  def resume_after_tool_approval(%State{} = state, _decisions, _opts) do
    Logger.warning(
      "[Turn] resume_after_tool_approval called on non-interrupted state status=#{state.status}"
    )

    state
  end

  # ── Resume helpers ──

  defp interrupt_id_list(interrupt_data, atom_key, string_key) do
    Handbeam.Utils.SafeMap.get_first_truthy(interrupt_data, atom_key, string_key) || []
  end

  defp decision_lookup(decisions) do
    Map.new(decisions, fn d ->
      {d["tool_call_id"] || d[:tool_call_id], d}
    end)
  end

  defp partition_hitl_decisions(hitl_ids, tool_calls, decision_by_id) do
    Enum.reduce(hitl_ids, {[], [], %{}, MapSet.new()}, fn call_id, acc ->
      call =
        Enum.find(
          tool_calls,
          &(Handbeam.Utils.SafeMap.get_first_truthy(&1, :id, "id") == call_id)
        )
      decision = Map.get(decision_by_id, call_id, %{})
      fold_hitl_decision(acc, call_id, call, decision)
    end)
  end

  defp fold_hitl_decision({calls, blocks, overrides, denied}, call_id, call, decision) do
    action =
      Handbeam.Utils.SafeMap.get_first_truthy(decision, "action", :action) || "deny"

    if to_string(action) == "approve" do
      {calls, blocks, remember_session_grant(overrides, decision, call), denied}
    else
      deny_hitl_call(%{
        calls: calls,
        blocks: blocks,
        overrides: overrides,
        denied: denied,
        call_id: call_id,
        call: call,
        decision: decision,
        action: action
      })
    end
  end

  defp deny_hitl_call(hitl) do
    tool_name =
      (hitl.call && (hitl.call[:name] || hitl.call["name"])) || hitl.decision["tool_name"] ||
        "unknown"

    block = denied_result_block(hitl.call_id, tool_name, hitl.action)
    new_overrides = remember_deny_override(hitl.overrides, hitl.decision, tool_name)

    {[hitl.call | hitl.calls], [block | hitl.blocks], new_overrides,
     MapSet.put(hitl.denied, hitl.call_id)}
  end

  defp remember_deny_override(overrides, decision, tool_name) do
    if Handbeam.Utils.SafeMap.get_first_truthy(decision, "remember", :remember) do
      Map.put(overrides, tool_name, :deny)
    else
      overrides
    end
  end

  defp calls_not_denied(tool_calls, denied_ids) do
    Enum.reject(tool_calls, fn call ->
      id = call[:id] || call["id"]
      MapSet.member?(denied_ids, id)
    end)
  end

  defp apply_approval_resume_state(state, denied_blocks, remembered_overrides) do
    {remembered_overrides, session_allow} = split_session_grants(remembered_overrides)
    merged_overrides = Map.merge(state.tool_guard_overrides || %{}, remembered_overrides)
    session_allow = Enum.uniq((state.tool_guard_session_allow || []) ++ session_allow)

    state
    |> Map.put(:status, :running)
    |> Map.put(:interrupt_data, nil)
    |> Map.put(:tool_guard_result_blocks, denied_blocks)
    |> Map.put(:tool_guard_overrides, merged_overrides)
    |> Map.put(:tool_guard_session_allow, session_allow)
  end

  defp continue_after_approval(state, [], denied_blocks, opts) do
    result_msg = Message.tool_results(denied_blocks |> Enum.reverse())

    state
    |> State.append_messages([result_msg])
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(opts, :steer)
    |> do_turn(opts)
  end

  defp continue_after_approval(state, approved_calls, denied_blocks, opts) do
    {executable, _already_denied} = executable_approved_calls(approved_calls, denied_blocks)

    case Executor.execute_all_with_details(executable, state) do
      {:ok, result_msg, ui_blocks} ->
        merge_approved_execution(%{
          state: state,
          approved_calls: approved_calls,
          executable: executable,
          result_msg: result_msg,
          ui_blocks: ui_blocks,
          denied_blocks: denied_blocks,
          opts: opts
        })
    end
  end

  defp executable_approved_calls(approved_calls, denied_blocks) do
    Enum.split_with(approved_calls, fn call ->
      id = Handbeam.Utils.SafeMap.get_first_truthy(call, :id, "id")

      not Enum.any?(
        denied_blocks,
        &(Handbeam.Utils.SafeMap.get_first_truthy(&1, :tool_use_id, "tool_use_id") == id)
      )
    end)
  end

  defp merge_approved_execution(execution) do
    all_ui_blocks =
      order_guarded_blocks(
        execution.approved_calls,
        execution.ui_blocks ++ execution.denied_blocks
      )

    merged_msg = %{
      execution.result_msg
      | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)
    }

    emit_tool_end_events(execution.executable, execution.ui_blocks, execution.opts)

    execution.state
    |> State.append_messages([merged_msg])
    |> Map.update!(:messages, &Handbeam.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(execution.opts, :steer)
    |> do_turn(execution.opts)
  end

  # "This session" remembers the suggested pattern, not `bash => :auto`.
  # A tool-name grant sits under the unsandboxed gate and would still skip every
  # later sandboxed prompt, including ones auto-review should see.
  defp remember_session_grant(overrides, decision, call) do
    if decision["remember"] || decision[:remember] do
      pattern =
        (call && Handbeam.Permissions.Remember.pattern(call)) ||
          decision["suggested_pattern"] || decision[:suggested_pattern]

      if is_binary(pattern) and String.trim(pattern) != "" do
        Map.put(overrides, {:session_allow, pattern}, :auto)
      else
        overrides
      end
    else
      overrides
    end
  end

  defp split_session_grants(overrides) do
    {grants, rest} =
      Enum.split_with(overrides, fn
        {{:session_allow, _pattern}, :auto} -> true
        _other -> false
      end)

    patterns =
      Enum.map(grants, fn {{:session_allow, pattern}, :auto} -> pattern end)

    {Map.new(rest), patterns}
  end

  defp last_tool_calls_from_state(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %Message{role: :assistant} = message ->
        case Message.tool_calls(message) do
          [] -> nil
          calls -> calls
        end

      _ ->
        nil
    end)
  end

  defp denied_result_block(tool_call_id, tool_name, action) do
    {content, permission} =
      case to_string(action) do
        "skip" ->
          {"Not selected this round. Request this action again.", :skipped}

        _ ->
          {"Tool call denied by user", :denied}
      end

    Message.tool_result_block(
      tool_call_id,
      content,
      true,
      %{permission: permission, tool: tool_name}
    )
  end

  defp blocked_tool_result_block(call, block_source) do
    call_id = call[:id] || call["id"]
    name = Handbeam.Utils.SafeMap.get_first_truthy(call, :name, "name")

    {content, blocked_by} =
      case block_source do
        {:extension, reason} ->
          {extension_block_content(name, reason), :extension}

        :active_set ->
          {"Tool call blocked: #{name} is not available at this stage", :active_set}
      end

    Message.tool_result_block(
      call_id,
      content,
      true,
      %{permission: :denied, blocked_by: blocked_by}
    )
  end

  defp extension_block_content(name, reason) do
    reason = to_string(reason)

    if String.trim(reason) == "" do
      "Tool call blocked: #{name} is not available at this stage"
    else
      "Tool call blocked: #{reason}"
    end
  end

  defp emit_tool_end_events(tool_calls, ui_blocks, opts) do
    ui_block_by_id =
      Map.new(ui_blocks, fn block ->
        {block[:tool_use_id] || block["tool_use_id"], block}
      end)

    Enum.each(tool_calls, fn call ->
      call_id = call[:id] || call["id"]
      ui_block = Map.get(ui_block_by_id, call_id)
      details = (ui_block && ui_block[:details]) || %{}

      file_path =
        details[:file_path] || details["file_path"] || call[:input][:file_path] ||
          call[:input]["file_path"]

      payload = %{
        tool_use_id: call_id,
        tool: call[:name] || call["name"],
        parent_tool_call_id: nil,
        duration_ms: 0,
        details: bounded_tool_details(details),
        file_path: file_path,
        images: Handbeam.Tool.Images.project(ui_block && ui_block[:images]),
        output: bounded_tool_output(ui_block && (ui_block[:content] || ui_block["content"]))
      }

      payload =
        if ui_block && ui_block[:is_error] do
          Map.put(payload, :error, bounded_tool_error(ui_block[:content] || ui_block["content"]))
        else
          payload
        end

      emit(opts, :tool_end, payload)
    end)
  end

  @doc """
  Run the agent loop until completion, error, or max turns.

  ## Options
    - `:streaming` - boolean, whether to use streaming (default: false)
    - `:on_chunk` - function called for each streamed chunk
    - `:on_event` - function called with `{:event_kind, payload}` tuples
  """
  @spec run_loop(State.t(), keyword()) :: State.t()
  def run_loop(%State{} = state, opts \\ []) do
    Logger.info(
      "[Turn] run_loop start model=#{state.config.model} " <>
        "max_turns=#{state.config.max_turns} streaming=#{Keyword.get(opts, :streaming, false)} " <>
        "messages=#{length(state.messages)}"
    )

    # session_start middleware
    state = mw_run(state, :session_start)

    # before_agent_start hook (blockable — call HookPipeline directly)
    state = check_before_agent_start(state, opts)

    if state.status == :halted do
      Logger.warning("[Turn] before_agent_start blocked: #{state.error}")

      emit(opts, :run_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        run_id: state.config.run_id
      })

      emit(opts, :agent_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        run_id: state.config.run_id
      })

      # session_end middleware
      mw_run(state, :session_end)
    else
      emit(opts, :run_start, %{model: state.config.model})

      run_start = System.monotonic_time(:millisecond)

      :telemetry.execute(
        [:handbeam, :run, :start],
        %{system_time: System.system_time()},
        %{model: state.config.model}
      )

      result = do_turn(state, opts)

      :telemetry.execute(
        [:handbeam, :run, :stop],
        %{duration_ms: System.monotonic_time(:millisecond) - run_start},
        %{status: result.status, turns: result.turn, model: state.config.model}
      )

      Logger.info(
        "[Turn] run_loop end status=#{result.status} turns=#{result.turn} " <>
          "duration_ms=#{System.monotonic_time(:millisecond) - run_start} " <>
          "usage=#{inspect(result.usage)}"
      )

      finish_run(result, opts)
    end
  end

  defp finish_run(result, opts) do
    payload = %{
      status: result.status,
      turns: result.turn,
      usage: result.usage,
      run_id: result.config.run_id
    }

    payload = if result.error, do: Map.put(payload, :error, result.error), else: payload

    payload =
      case result.interrupt_data do
        %{signal: signal, evidence: evidence} ->
          payload |> Map.put(:signal, signal) |> Map.put(:evidence, evidence)

        _ ->
          payload
      end

    emit(opts, :run_end, payload)
    emit(opts, :agent_end, payload)
    mw_run(result, :session_end)
  end

  # ── before_agent_start hook ──

  defp check_before_agent_start(state, opts) do
    session_id = Keyword.get(opts, :session_id)

    if session_id do
      payload = %{
        model: state.config.model,
        max_turns: state.config.max_turns
      }

      case run_extension_hook(state, session_id, {:before_agent_start, payload}) do
        {:block, reason} ->
          %{state | status: :halted, error: "Blocked by extension: #{reason}"}

        {:transform, transformed} ->
          # Whitelist: system_prompt, metadata only (per spec S2.1)
          config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) -> %{state.config | system_prompt: prompt}
              _ -> state.config
            end

          state =
            case Map.fetch(transformed, :metadata) do
              {:ok, meta} when is_map(meta) -> State.merge_run_metadata(state, meta)
              _ -> state
            end

          %{state | config: config}

        _ ->
          state
      end
    else
      state
    end
  end

  # ── context hook ──

  defp apply_context_hook(state, provider_config, opts) do
    session_id = Keyword.get(opts, :session_id)
    messages = State.messages(state)

    if session_id do
      payload = %{
        messages: messages,
        system_prompt: provider_config.system_prompt
      }

      case run_extension_hook(state, session_id, {:context, payload}) do
        {:block, reason} ->
          {:block, reason}

        {:transform, transformed} ->
          # Request-scoped only: outbound messages + system_prompt for this
          # provider call. Durable State / transcript stay untouched.
          outbound_messages =
            case Map.fetch(transformed, :messages) do
              {:ok, msgs} when is_list(msgs) -> msgs
              _ -> messages
            end

          provider_config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) ->
                %{provider_config | system_prompt: prompt}

              _ ->
                provider_config
            end

          {outbound_messages, provider_config}

        _ ->
          {messages, provider_config}
      end
    else
      {messages, provider_config}
    end
  end

  # ── Middleware helper ──

  defp run_extension_hook(%State{config: %{delegated?: true}}, _session_id, _event),
    do: :ok

  defp run_extension_hook(_state, session_id, event), do: HookPipeline.run(session_id, event)

  defp mw_run(%State{} = state, hook) do
    middleware = state.config.middleware || []

    case Middleware.run(hook, state, middleware) do
      {:halted, _reason} -> %{state | status: :halted}
      {:interrupted, %State{} = s, _data} -> s
      {:tool_guard_denied, %State{} = s} -> s
      %State{} = s -> s
    end
  end

  # ── Event helper ──

  defp emit(opts, kind, payload) do
    log_emit(kind, payload)

    case Keyword.get(opts, :on_event) do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        # Suppress per-chunk logging for message_delta to avoid
        # flooding the console during SSE streaming (50-500+ chunks/turn).
        fun.({kind, payload})
    end
  end

  defp notify_progress(opts, kind) do
    case Keyword.get(opts, :on_progress) do
      fun when is_function(fun, 1) -> fun.(kind)
      _ -> :ok
    end
  end

  defp emit_provider_items(opts, messages) do
    items =
      messages
      |> Enum.flat_map(fn
        %Handbeam.Agent.Message{content: blocks} when is_list(blocks) ->
          Enum.filter(blocks, fn
            %{type: "responses_reasoning"} ->
              true

            %{"type" => "responses_reasoning"} ->
              true

            %{type: "text", phase: phase} when phase in ["commentary", "final_answer"] ->
              true

            %{"type" => "text", "phase" => phase} when phase in ["commentary", "final_answer"] ->
              true

            _ ->
              false
          end)

        _ ->
          []
      end)

    if items != [], do: emit(opts, :provider_items, %{items: items})
  end

  defp emit_assistant_messages(opts, messages) do
    Enum.each(messages, fn
      %Message{role: :assistant} = msg ->
        text = Message.text(msg)

        if is_binary(text) and text != "" do
          emit(opts, :message_delta, %{chunk: text})
        end

      _ ->
        :ok
    end)
  end

  # A commentary-only Codex message is visible, but it is not the final answer.
  # Retry once with that commentary in history. A truly blank assistant message
  # is still an empty turn.
  defp missing_final_answer?(messages) do
    assistant_messages = Enum.filter(messages, &match?(%Message{role: :assistant}, &1))

    cond do
      assistant_messages == [] ->
        false

      Enum.any?(assistant_messages, &final_answer?/1) ->
        false

      Enum.any?(assistant_messages, &(Message.tool_calls(&1) != [])) ->
        false

      true ->
        Enum.all?(assistant_messages, fn message ->
          commentary_only?(message) or not visible_assistant_text?(message)
        end)
    end
  end

  defp final_answer?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn block ->
      is_map(block) and block[:type] == "text" and block[:phase] == "final_answer" and
        is_binary(block[:text]) and String.trim(block[:text]) != ""
    end)
  end

  defp final_answer?(%Message{content: text}) when is_binary(text), do: String.trim(text) != ""
  defp final_answer?(_), do: false

  defp commentary_only?(%Message{content: blocks}) when is_list(blocks) do
    text_blocks = Enum.filter(blocks, &(is_map(&1) and &1[:type] == "text"))

    text_blocks != [] and
      Enum.all?(text_blocks, fn block ->
        block[:phase] == "commentary" and is_binary(block[:text]) and
          String.trim(block[:text]) != ""
      end)
  end

  defp commentary_only?(_), do: false

  defp commentary_only_turn?(messages) do
    messages != [] and Enum.all?(messages, &commentary_only?/1)
  end

  defp visible_assistant_text?(%Message{} = message) do
    case Message.text(message) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  # ── Turn loop ──

  defp do_turn(%State{status: :interrupted} = state, opts) do
    if stall_check?(state) do
      emit(opts, :stall_check_requested, state.interrupt_data)
    end

    state
  end

  defp do_turn(%State{status: status} = state, _opts)
       when status in [:stalled, :max_turns, :error, :halted, :budget_exceeded] do
    state
  end

  defp do_turn(%State{turn: turn, config: config} = state, _opts)
       when turn >= config.max_turns do
    Logger.warning(fn -> "[Turn] max_turns reached turn=#{turn} max=#{config.max_turns}" end)
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state, opts) do
    turn_number = state.turn + 1

    # turn_start hook (read-only notification)
    emit(opts, :turn_start, %{turn: turn_number})

    :telemetry.execute(
      [:handbeam, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: turn_number}
    )

    state =
      state
      |> maybe_compact()
      |> inject_candidate_messages(opts, :steer)
      |> mw_run(:before_completion)

    Logger.debug(
      "[Turn] start turn=#{turn_number} messages=#{length(state.messages)} " <>
        "model=#{state.config.model}"
    )

    if state.status == :halted do
      :telemetry.execute(
        [:handbeam, :turn, :stop],
        %{duration_ms: 0},
        %{turn: turn_number, status: :halted}
      )

      # turn_end hook (read-only notification)
      emit(opts, :turn_end, %{turn: turn_number, stop_reason: "halted", status: :halted})

      state
    else
      t0 = System.monotonic_time(:millisecond)
      result = do_completion(state, opts)
      duration_ms = System.monotonic_time(:millisecond) - t0

      Logger.debug(
        "[Turn] stop turn=#{turn_number} status=#{result.status} duration_ms=#{duration_ms}"
      )

      :telemetry.execute(
        [:handbeam, :turn, :stop],
        %{duration_ms: duration_ms},
        %{turn: turn_number, status: result.status}
      )

      # turn_end hook (read-only notification)
      emit(opts, :turn_end, %{turn: turn_number, stop_reason: "completed", status: result.status})

      result
    end
  end

  # Apply Compactor before each provider call so a long-running conversation
  # cannot indefinitely grow the message history and stall the provider with
  # oversized payloads.
  defp maybe_compact(%State{} = state) do
    case Compactor.maybe_compact(state) do
      {:compacted, compacted} ->
        Logger.info(
          "[Turn] context compacted before=#{length(state.messages)} " <>
            "after=#{length(compacted.messages)} max_tokens=#{state.config.max_tokens}"
        )

        :telemetry.execute(
          [:handbeam, :compaction, :done],
          %{messages_before: length(state.messages), messages_after: length(compacted.messages)},
          %{turn: state.turn + 1}
        )

        case Middleware.run(:after_compaction, compacted, state.config.middleware || []) do
          {:halted, reason} ->
            %{compacted | status: :halted, error: "Halted by middleware: #{reason}"}

          %State{} = s ->
            s
        end

      {:unchanged, state} ->
        state
    end
  end

  defp do_completion(%State{} = state, opts) do
    provider_config =
      state
      |> build_provider_config()
      |> Map.put(:run_deadline, Keyword.get(opts, :run_deadline))

    case apply_context_hook(state, provider_config, opts) do
      {:block, reason} -> %{state | status: :halted, error: "Blocked by extension: #{reason}"}
      {messages, config} -> do_provider_completion(state, opts, messages, config)
    end
  end

  defp do_provider_completion(state, opts, outbound_messages, provider_config) do
    provider = state.config.provider
    streaming? = Keyword.get(opts, :streaming, false)
    {chunk_tracker, streamed_text_tracker} = start_stream_trackers(streaming?)
    on_chunk = completion_on_chunk(opts, streaming?, chunk_tracker, streamed_text_tracker)
    provider_config = prepare_completion_config(provider_config, opts, streaming?, on_chunk)
    {provider_config, tool_defs} = completion_tool_defs(state, opts, provider_config)

    Logger.debug(
      "[Turn] provider call provider=#{inspect(provider)} streaming=#{streaming?} " <>
        "tool_defs=#{length(tool_defs)} messages=#{length(outbound_messages)}"
    )

    provider_t0 = System.monotonic_time(:millisecond)

    completion = %{
      provider: provider,
      state: state,
      outbound_messages: outbound_messages,
      tool_defs: tool_defs,
      provider_config: provider_config,
      streaming?: streaming?,
      on_chunk: on_chunk,
      chunk_tracker: chunk_tracker,
      streamed_text_tracker: streamed_text_tracker,
      opts: opts
    }

    {provider_result, streamed_text} = invoke_provider_completion(completion)

    dispatch_provider_result(provider_result, completion, streamed_text, provider_t0)
  end

  defp start_stream_trackers(false), do: {nil, nil}

  defp start_stream_trackers(true) do
    tracker = Agent.start_link(fn -> %{text: "", phases: %{}} end)
    {:counters.new(1, []), elem(tracker, 1)}
  end

  defp completion_on_chunk(opts, streaming?, chunk_tracker, streamed_text_tracker) do
    cond do
      is_function(Keyword.get(opts, :on_chunk), 1) ->
        user_on_chunk = Keyword.fetch!(opts, :on_chunk)
        user_completion_chunk(opts, chunk_tracker, streamed_text_tracker, user_on_chunk)

      streaming? ->
        streamed_completion_chunk(opts, chunk_tracker, streamed_text_tracker)

      true ->
        nil
    end
  end

  defp user_completion_chunk(opts, chunk_tracker, streamed_text_tracker, user_on_chunk) do
    fn chunk ->
      track_chunk(chunk_tracker, chunk_text(chunk))
      track_streamed_text(streamed_text_tracker, chunk)
      notify_progress(opts, :message_delta)
      user_on_chunk.(chunk_text(chunk))
    end
  end

  defp streamed_completion_chunk(opts, chunk_tracker, streamed_text_tracker) do
    fn chunk ->
      track_chunk(chunk_tracker, chunk_text(chunk))
      track_streamed_text(streamed_text_tracker, chunk)
      emit_stream_chunk(opts, chunk)
    end
  end

  defp prepare_completion_config(provider_config, opts, streaming?, on_chunk) do
    provider_config
    |> Map.put(:stream, streaming?)
    |> Map.put(:retry_owner, :turn)
    |> maybe_put_provider_event_callback(opts)
    |> maybe_put_on_chunk(on_chunk)
  end

  defp maybe_put_on_chunk(provider_config, on_chunk) do
    if is_function(on_chunk, 1),
      do: Map.put(provider_config, :on_chunk, on_chunk),
      else: provider_config
  end

  defp completion_tool_defs(state, opts, provider_config) do
    authorized_tools = Executor.authorized_tools(state.config)

    tool_defs =
      opts
      |> Keyword.get(:session_id)
      |> session_tool_defs()
      |> Handbeam.MCP.Access.filter(state.config.context)
      |> Enum.filter(&(&1.name in authorized_tools))
      |> Enum.map(
        &Handbeam.Tool.Builtin.Task.contextualize_def(&1, state.config, authorized_tools)
      )

    final_turn? = state.turn + 1 >= state.config.max_turns
    provider_config = maybe_require_final_answer(provider_config, final_turn?)
    tool_defs = if final_turn?, do: [], else: tool_defs
    {provider_config, tool_defs}
  end

  defp session_tool_defs(nil), do: Handbeam.Tool.Registry.tool_defs()
  defp session_tool_defs(sid), do: Handbeam.Tool.Registry.tool_defs_for_session(sid)

  defp invoke_provider_completion(completion) do
    try do
      result =
        call_provider_with_retry(
          completion.provider,
          completion.state,
          completion.outbound_messages,
          completion.tool_defs,
          completion.provider_config,
          completion.streaming?,
          completion.on_chunk,
          completion.chunk_tracker,
          0,
          completion.opts
        )

      {result, take_streamed_text(completion.streamed_text_tracker)}
    after
      stop_streamed_text_tracker(completion.streamed_text_tracker)
    end
  end

  defp dispatch_provider_result(
         {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage} = response},
         completion,
         _streamed_text,
         provider_t0
       ) do
    accept_tool_use_response(completion, new_msgs, usage, response, provider_t0)
  end

  defp dispatch_provider_result(
         {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage} = response},
         completion,
         streamed_text,
         provider_t0
       ) do
    accept_end_turn_response(completion, new_msgs, usage, response, streamed_text, provider_t0)
  end

  defp dispatch_provider_result({:error, reason}, completion, _streamed_text, provider_t0) do
    handle_provider_error(completion, reason, provider_t0)
  end

  defp accept_tool_use_response(completion, new_msgs, usage, response, provider_t0) do
    Logger.debug(
      "[Turn] provider returned tool_use new_msgs=#{length(new_msgs)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0}"
    )

    state =
      record_provider_response(
        completion.state,
        completion.opts,
        new_msgs,
        usage,
        response,
        :after_tool_request
      )

    continue_after_tool_request(state, new_msgs, completion.opts)
  end

  defp accept_end_turn_response(completion, new_msgs, usage, response, streamed_text, provider_t0) do
    Logger.debug(
      "[Turn] provider returned end_turn new_msgs=#{length(new_msgs)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
        "usage=#{inspect(usage)}"
    )

    state =
      record_provider_response(
        completion.state,
        completion.opts,
        new_msgs,
        usage,
        response,
        :after_completion
      )

    emit_completion_messages(
      completion.opts,
      new_msgs,
      completion.streaming?,
      completion.chunk_tracker,
      streamed_text
    )

    continue_after_end_turn(state, new_msgs, completion.opts)
  end

  defp record_provider_response(state, opts, new_msgs, usage, response, middleware) do
    emit_provider_items(opts, new_msgs)

    state =
      state
      |> State.append_messages(new_msgs)
      |> State.increment_turn()
      |> State.merge_usage(usage)
      |> State.merge_provider_state(Map.get(response, :provider_state, %{}))
      |> State.put_provider_response_metadata(Map.get(response, :response_metadata, %{}))

    emit(opts, :usage_updated, %{usage: state.usage})
    if state.config.delegated?, do: emit(opts, :delegation_usage, state.usage)
    mw_run(state, middleware)
  end

  defp continue_after_tool_request(%State{status: :interrupted} = state, _new_msgs, opts) do
    emit(opts, :tool_approval_requested, state.interrupt_data || %{})
    state
  end

  # Auto-review can latch a stop inside this batch. Do not execute the
  # approved siblings; the turn is already over.
  defp continue_after_tool_request(%State{status: :halted} = state, new_msgs, opts) do
    finish_halted_tool_review(state, new_msgs, opts)
  end

  defp continue_after_tool_request(state, new_msgs, opts) do
    handle_tool_use(state, new_msgs, opts)
  end

  defp continue_after_end_turn(state, new_msgs, opts) do
    cond do
      missing_final_answer?(new_msgs) and not Keyword.get(opts, :empty_end_turn_retried, false) ->
        retry_missing_final_answer(state, opts)

      missing_final_answer?(new_msgs) ->
        fail_missing_final_answer(state, new_msgs)

      true ->
        continue_with_pending_or_complete(state, opts)
    end
  end

  defp retry_missing_final_answer(state, opts) do
    Logger.warning("[Turn] commentary without a final answer — requesting the final answer once")
    do_turn(state, Keyword.put(opts, :empty_end_turn_retried, true))
  end

  defp fail_missing_final_answer(state, new_msgs) do
    error_msg = missing_final_answer_error(new_msgs)
    Logger.warning("[Turn] #{error_msg}")

    state
    |> Map.put(:status, :error)
    |> Map.put(:error, error_msg)
    |> mw_run(:on_error)
  end

  defp missing_final_answer_error(new_msgs) do
    if commentary_only_turn?(new_msgs),
      do: "Provider ended the turn without a final answer",
      else: "Provider ended the turn with no visible assistant response or tool call"
  end

  defp handle_provider_error(completion, reason, provider_t0) do
    error_msg = format_provider_error(completion.provider_config, reason)

    if not Keyword.get(completion.opts, :prompt_too_long_retried, false) and
         prompt_too_long?(error_msg) do
      retry_prompt_too_long(completion.state, completion.opts, error_msg)
    else
      continue_or_fail_provider_error(
        completion.state,
        completion.opts,
        completion.provider,
        error_msg,
        provider_t0
      )
    end
  end

  defp retry_prompt_too_long(state, opts, error_msg) do
    Logger.info("[Turn] Prompt too long — forcing compaction and retrying")
    compacted_state = Compactor.force_compact(state)

    if compacted_state.messages == state.messages do
      state = %{state | status: :error, error: error_msg}
      mw_run(state, :on_error)
    else
      do_completion(compacted_state, Keyword.put(opts, :prompt_too_long_retried, true))
    end
  end

  defp continue_or_fail_provider_error(state, opts, provider, error_msg, provider_t0) do
    follow_ups = drain_candidate_messages(opts, :follow_up)

    if follow_ups != [] and not Keyword.get(opts, :error_follow_up_retried, false) do
      Logger.warning(
        "[Turn] provider error, continuing with queued follow_up " <>
          "count=#{length(follow_ups)} error=#{error_msg}"
      )

      continue_with_follow_up(
        state,
        follow_ups,
        Keyword.put(opts, :error_follow_up_retried, true)
      )
    else
      fail_provider_error(state, provider, error_msg, provider_t0)
    end
  end

  defp fail_provider_error(state, provider, error_msg, provider_t0) do
    Logger.error(
      "[Turn] Provider error provider=#{inspect(provider)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
        "error=#{error_msg}"
    )

    state = %{state | status: :error, error: error_msg}
    mw_run(state, :on_error)
  end

  defp continue_with_follow_up(state, follow_up_messages, opts) do
    Logger.debug("[Turn] draining follow_up messages count=#{length(follow_up_messages)}")
    emit_candidate_injected(opts, :follow_up, follow_up_messages)

    state
    |> State.append_messages(follow_up_messages)
    |> do_turn(opts)
  end

  defp continue_with_pending_or_complete(state, opts) do
    case Keyword.get(opts, :candidate_queue) do
      nil ->
        maybe_review_or_complete(state, opts, nil)

      queue ->
        if Handbeam.Agent.CandidateQueue.has_pending?(queue) do
          inject_pending(state, opts, queue)
        else
          maybe_review_or_complete(state, opts, queue)
        end
    end
  end

  defp maybe_review_or_complete(state, opts, queue) do
    if Handbeam.Agent.Advisor.review?(state.advisor) do
      review_before_seal(state, opts, queue)
    else
      seal_or_complete(state, opts, queue)
    end
  end

  defp review_before_seal(state, opts, queue) do
    digest = artifact_digest(state)
    request_id = "advisor-review-" <> Ecto.UUID.generate()

    state = %{
      state
      | advisor: %{
          state.advisor
          | phase: :reviewing,
            request_id: request_id,
            artifact_digest: digest
        }
    }

    case Handbeam.Agent.Advisor.review(state, opts, request_id, digest) do
      {:pass, advisor} ->
        state = %{state | advisor: advisor}
        seal_or_complete(state, opts, queue)

      {:revise, advisor, feedback} ->
        state
        |> Map.put(:advisor, advisor)
        |> State.append_messages([Handbeam.Agent.Message.user(feedback)])
        |> do_turn(opts)

      {:blocked, advisor, reason} ->
        %{state | advisor: advisor, status: :error, error: "尚未通过验收: #{reason}"}

      {:stale, advisor} ->
        %{state | advisor: advisor}
        |> do_turn(opts)
    end
  end

  defp seal_or_complete(state, _opts, nil), do: %{state | status: :completed}

  defp seal_or_complete(state, opts, queue) do
    case Handbeam.Agent.CandidateQueue.take_pending_or_seal(queue) do
      :sealed ->
        %{state | status: :completed}

      {:pending, %{steer: steer, follow_up: follow_ups}} ->
        emit_candidate_injected(opts, :steer, steer)
        emit_candidate_injected(opts, :follow_up, follow_ups)

        state
        |> State.append_messages(steer ++ follow_ups)
        |> do_turn(opts)
    end
  end

  defp inject_pending(state, opts, queue) do
    case Handbeam.Agent.CandidateQueue.take_pending_or_seal(queue) do
      {:pending, %{steer: steer, follow_up: follow_ups}} ->
        emit_candidate_injected(opts, :steer, steer)
        emit_candidate_injected(opts, :follow_up, follow_ups)

        state
        |> State.append_messages(steer ++ follow_ups)
        |> do_turn(opts)

      :sealed ->
        %{state | status: :completed}
    end
  end

  defp stall_check?(%State{interrupt_data: %{type: :stall_check}}), do: true
  defp stall_check?(_state), do: false

  def resume_after_stall_check(%State{status: :interrupted} = state, _decisions, opts) do
    state = %{
      state
      | status: :running,
        interrupt_data: nil,
        progress:
          Handbeam.Agent.ProgressGuard.grant(
            state.progress || Handbeam.Agent.ProgressGuard.initial()
          )
    }

    state
    |> do_turn(opts)
    |> finish_run(opts)
  end

  def resume_after_stall_check(%State{} = state, _decisions, _opts), do: state

  defp artifact_digest(state) do
    state.messages
    |> Enum.map_join("\n", &Handbeam.Agent.Message.text/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp call_provider_with_retry(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         loop_opts
       ) do
    result =
      call_provider(provider, outbound_messages, tool_defs, provider_config, streaming?, on_chunk)

    case result do
      {:error, reason} ->
        retry_config = retry_config(state, provider_config)

        case {Retry.should_retry_error?(reason, attempt, retry_config),
              chunks_emitted?(chunk_tracker)} do
          {{:retry, _delay_ms}, false} ->
            if uncertain_cursor_error?(reason) do
              result
            else
              remaining = remaining_budget_ms(loop_opts)

              case Retry.delay_ms(attempt, retry_config,
                     retry_after_ms: retry_after_ms(reason),
                     remaining_ms: remaining
                   ) do
                :budget_exceeded ->
                  {:error, {:run_budget_exceeded, reason}}

                delay_ms ->
                  retry_provider_call(
                    provider,
                    state,
                    outbound_messages,
                    tool_defs,
                    provider_config,
                    streaming?,
                    on_chunk,
                    chunk_tracker,
                    attempt,
                    delay_ms,
                    reason,
                    loop_opts
                  )
              end
            end

          {_retry_result, _chunks_emitted?} ->
            result
        end

      _ ->
        result
    end
  end

  defp retry_provider_call(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         delay_ms,
         reason,
         loop_opts
       ) do
    notify_progress(loop_opts, :provider_retry)

    Logger.warning(fn ->
      "[Turn] provider transient error, retrying attempt=#{attempt + 1} " <>
        "delay_ms=#{delay_ms} error=#{format_error(reason)}"
    end)

    parent = self()

    receive do
      :run_cancelled ->
        {:error, {:run_cancelled, reason}}
    after
      0 ->
        if not interruptible_sleep(delay_ms, loop_opts, parent) do
          {:error, {:run_budget_exceeded, reason}}
        else
          retry_after_sleep(
            provider,
            state,
            outbound_messages,
            tool_defs,
            provider_config,
            streaming?,
            on_chunk,
            chunk_tracker,
            attempt,
            loop_opts
          )
        end
    end
  end

  defp retry_after_sleep(
         provider,
         state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         loop_opts
       ) do
    call_provider_with_retry(
      provider,
      state,
      outbound_messages,
      tool_defs,
      provider_config,
      streaming?,
      on_chunk,
      chunk_tracker,
      attempt + 1,
      loop_opts
    )
  end

  defp remaining_budget_ms(opts) do
    case Keyword.get(opts, :run_deadline) do
      deadline when is_integer(deadline) ->
        max(deadline - System.monotonic_time(:millisecond), 0)

      _ ->
        nil
    end
  end

  defp retry_after_ms(%{retry_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms

  defp retry_after_ms(%{headers: headers}) when is_list(headers) or is_map(headers) do
    header =
      Enum.find_value(headers, fn
        {key, value} -> if String.downcase(to_string(key)) == "retry-after", do: value
        _ -> nil
      end)

    if header, do: Handbeam.Agent.Provider.Retry.parse_retry_after(to_string(header)), else: 0
  end

  defp retry_after_ms(_reason), do: 0

  defp interruptible_sleep(delay_ms, opts, parent) do
    deadline = Keyword.get(opts, :run_deadline)

    wait =
      if is_integer(deadline),
        do: min(delay_ms, max(deadline - System.monotonic_time(:millisecond), 0)),
        else: delay_ms

    if wait <= 0 do
      false
    else
      ref = Process.monitor(parent)

      result =
        receive do
          :run_deadline_interrupt -> false
          :run_cancelled -> false
          {:DOWN, ^ref, :process, ^parent, _reason} -> false
        after
          wait -> is_nil(deadline) or System.monotonic_time(:millisecond) < deadline
        end

      Process.demonitor(ref, [:flush])
      result
    end
  end

  defp call_provider(provider, messages, tool_defs, provider_config, true, on_chunk)
       when is_list(messages) and is_function(on_chunk, 1) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 4) do
      provider.stream(messages, tool_defs, provider_config, on_chunk)
    else
      provider.complete(messages, tool_defs, provider_config)
    end
  end

  defp call_provider(provider, messages, tool_defs, provider_config, _streaming?, _on_chunk)
       when is_list(messages) do
    provider.complete(messages, tool_defs, provider_config)
  end

  defp retry_config(%State{config: config}, provider_config) do
    provider_config
    |> Map.put_new(:max_retries, Map.get(config.provider_config, :max_retries, 3))
    |> Map.put_new(
      :retry_delay_base_ms,
      Map.get(config.provider_config, :retry_delay_base_ms, 500)
    )
  end

  defp track_chunk(nil, _chunk), do: :ok
  defp track_chunk(_counter, ""), do: :ok
  defp track_chunk(counter, chunk) when is_binary(chunk), do: :counters.add(counter, 1, 1)

  defp chunk_text(%{text: text}) when is_binary(text), do: text
  defp chunk_text(text) when is_binary(text), do: text
  defp chunk_text(_chunk), do: ""

  defp emit_stream_chunk(opts, %{text: text, phase: phase, output_index: index})
       when is_binary(text) and text != "" and is_integer(index) do
    emit(opts, :message_delta, %{chunk: text, phase: phase, output_index: index})
  end

  defp emit_stream_chunk(opts, chunk) when is_binary(chunk) and chunk != "" do
    emit(opts, :message_delta, %{chunk: chunk})
  end

  defp emit_stream_chunk(_opts, _chunk), do: :ok

  defp track_streamed_text(nil, _chunk), do: :ok
  defp track_streamed_text(_agent, ""), do: :ok

  defp track_streamed_text(agent, chunk) when is_binary(chunk) do
    Agent.update(agent, fn streamed ->
      %{streamed | text: streamed.text <> chunk}
    end)
  end

  defp track_streamed_text(agent, %{text: text, phase: phase, output_index: index})
       when is_binary(text) and is_integer(index) do
    Agent.update(agent, fn streamed ->
      phases =
        Map.update(streamed.phases, index, %{phase: phase, text: text}, fn current ->
          %{current | phase: phase, text: current.text <> text}
        end)

      %{streamed | text: streamed.text <> text, phases: phases}
    end)
  end

  defp track_streamed_text(_agent, _chunk), do: :ok

  defp take_streamed_text(nil), do: %{text: "", phases: %{}}

  defp take_streamed_text(agent) do
    case Agent.get(agent, & &1) do
      %{text: text, phases: phases} = streamed when is_binary(text) and is_map(phases) -> streamed
      text when is_binary(text) -> %{text: text, phases: %{}}
      _ -> %{text: "", phases: %{}}
    end
  end

  defp stop_streamed_text_tracker(nil), do: :ok

  defp stop_streamed_text_tracker(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  defp chunks_emitted?(nil), do: false
  defp chunks_emitted?(counter), do: :counters.get(counter, 1) > 0

  defp maybe_put_provider_event_callback(provider_config, opts) do
    case Keyword.get(opts, :on_event) do
      fun when is_function(fun, 1) -> Map.put(provider_config, :on_event, fun)
      _ -> provider_config
    end
  end

  defp emit_completion_messages(opts, new_msgs, false, _chunk_tracker, _streamed_text) do
    Logger.debug("[Turn] emitting completion messages non_streaming count=#{length(new_msgs)}")
    emit_assistant_messages(opts, new_msgs)
  end

  defp emit_completion_messages(opts, new_msgs, true, chunk_tracker, streamed_text) do
    if chunks_emitted?(chunk_tracker) do
      maybe_emit_streaming_completion_tail(opts, new_msgs, streamed_text)
    else
      Logger.debug(
        "[Turn] streaming produced no chunks; emitting final messages count=#{length(new_msgs)}"
      )

      emit_assistant_messages(opts, new_msgs)
    end
  end

  defp maybe_emit_streaming_completion_tail(opts, new_msgs, %{phases: phases})
       when map_size(phases) > 0 do
    new_msgs
    |> Enum.filter(&match?(%Message{role: :assistant}, &1))
    |> Enum.flat_map(&text_blocks/1)
    |> Enum.with_index()
    |> Enum.each(fn {block, index} ->
      streamed_block = Map.get(phases, index, %{text: "", phase: nil})
      emit_unstreamed_tail(opts, block, streamed_block, index)
    end)
  end

  defp maybe_emit_streaming_completion_tail(opts, new_msgs, %{text: streamed}) do
    final_text =
      new_msgs
      |> Enum.filter(&match?(%Message{role: :assistant}, &1))
      |> Enum.map_join(fn msg -> Message.text(msg) || "" end)

    emit_text_tail(opts, final_text, streamed, nil)
  end

  defp text_blocks(%Message{content: blocks}) when is_list(blocks) do
    Enum.filter(blocks, &(is_map(&1) and &1[:type] == "text" and is_binary(&1[:text])))
  end

  defp text_blocks(%Message{content: text}) when is_binary(text),
    do: [%{type: "text", text: text}]

  defp text_blocks(_), do: []

  defp emit_unstreamed_tail(opts, block, streamed_block, index) do
    phase = block[:phase] || streamed_block[:phase]

    cond do
      streamed_block.text == "" ->
        emit(opts, :message_delta, stream_payload(block.text, phase, index))

      streamed_block.text == block.text ->
        :ok

      String.starts_with?(block.text, streamed_block.text) ->
        tail =
          binary_part(
            block.text,
            byte_size(streamed_block.text),
            byte_size(block.text) - byte_size(streamed_block.text)
          )

        emit(opts, :message_delta, stream_payload(tail, phase, index))

      true ->
        Logger.debug(
          "[Turn] streaming assistant text diverged from chunks; keeping streamed text"
        )
    end
  end

  defp emit_text_tail(_opts, "", _streamed, _phase), do: :ok

  defp emit_text_tail(_opts, final_text, streamed, _phase) when final_text == streamed do
    Logger.debug("[Turn] streaming chunks already match final assistant text; skip replay")
  end

  defp emit_text_tail(opts, final_text, streamed, phase) when is_binary(streamed) do
    cond do
      String.starts_with?(final_text, streamed) ->
        tail =
          binary_part(
            final_text,
            byte_size(streamed),
            byte_size(final_text) - byte_size(streamed)
          )

        emit(opts, :message_delta, stream_payload(tail, phase, nil))

      true ->
        Logger.debug(
          "[Turn] streaming final assistant text diverged from streamed chunks; keeping streamed text"
        )
    end
  end

  defp emit_text_tail(_opts, _final_text, _streamed, _phase), do: :ok

  defp stream_payload(text, phase, index) do
    payload = %{chunk: text}
    payload = if is_binary(phase), do: Map.put(payload, :phase, phase), else: payload
    if is_integer(index), do: Map.put(payload, :output_index, index), else: payload
  end

  defp inject_candidate_messages(%State{} = state, opts, deliver_as) do
    case drain_candidate_messages(opts, deliver_as) do
      [] ->
        state

      messages ->
        emit_candidate_injected(opts, deliver_as, messages)
        State.append_messages(state, messages)
    end
  end

  defp drain_candidate_messages(opts, :steer) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbeam.Agent.CandidateQueue.drain_steer(queue)
    end
  end

  defp drain_candidate_messages(opts, :follow_up) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbeam.Agent.CandidateQueue.drain_follow_up(queue)
    end
  end

  defp emit_candidate_injected(opts, deliver_as, messages) do
    emit(opts, :candidate_message_injected, %{
      deliver_as: deliver_as,
      count: length(messages),
      message_ids: Enum.map(messages, & &1.id)
    })
  end

  defp log_emit(:message_delta, %{chunk: _chunk}), do: :ok

  defp log_emit(kind, payload) do
    Logger.debug("[Turn] emit #{kind} keys=#{inspect(Map.keys(payload || %{}))}")
  end

  defp finish_halted_tool_review(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)

    denied_by_id =
      Map.new(state.tool_guard_result_blocks || [], fn block ->
        {block[:tool_use_id] || block["tool_use_id"], block}
      end)

    blocks =
      Enum.map(tool_calls, fn call ->
        id = call[:id] || call["id"]

        Map.get(denied_by_id, id) ||
          Message.tool_result_block(
            id,
            state.error || Handbeam.Permissions.AutoReview.halt_error(),
            true,
            %{
              permission: :denied,
              tool: call[:name] || call["name"],
              reviewer: :auto_review
            }
          )
      end)

    Enum.each(blocks, fn block ->
      emit(opts, :tool_end, %{
        tool_use_id: block[:tool_use_id],
        tool: get_in(block, [:details, :tool]) || "unknown",
        duration_ms: 0,
        details: bounded_tool_details(block[:details] || %{}),
        error: bounded_tool_error(block[:content]),
        output: bounded_tool_output(block[:content])
      })
    end)

    state
    |> State.append_messages([Message.tool_results(blocks)])
    |> Map.put(:status, :halted)
  end

  defp handle_tool_use(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)
    session_id = Keyword.get(opts, :session_id)

    Logger.debug(
      "[Turn] handle_tool_use count=#{length(tool_calls)} tools=#{inspect(Enum.map(tool_calls, & &1[:name]))}"
    )

    active_set = if session_id, do: Handbeam.Tool.Registry.active_for_session(session_id)

    {blocked_calls, allowed_calls_w_ctx} =
      gate_tool_calls(state, tool_calls, session_id, active_set)

    {blocked_calls, allowed_calls_w_ctx} =
      reject_unauthorized_rewrites(state, blocked_calls, allowed_calls_w_ctx, active_set)

    emit_allowed_tool_starts(allowed_calls_w_ctx, opts)

    denied_blocks =
      Enum.map(blocked_calls, fn {call, block_source} ->
        blocked_tool_result_block(call, block_source)
      end)

    allowed_calls = Enum.map(allowed_calls_w_ctx, fn {call, _ctx} -> call end)
    execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts)
  end

  defp gate_tool_calls(_state, tool_calls, nil, _active_set) do
    {[], Enum.map(tool_calls, &{&1, %{}})}
  end

  defp gate_tool_calls(state, tool_calls, session_id, active_set) do
    {blocked, allowed} =
      Enum.reduce(tool_calls, {[], []}, fn call, acc ->
        fold_tool_call_gate(state, session_id, active_set, call, acc)
      end)

    {Enum.reverse(blocked), Enum.reverse(allowed)}
  end

  defp fold_tool_call_gate(state, session_id, active_set, call, {blocked, allowed}) do
    case run_extension_hook(state, session_id, tool_call_hook_event(call, session_id)) do
      {:block, reason} ->
        {[{call, {:extension, reason}} | blocked], allowed}

      {:transform, %{args: transformed_args} = ctx} when is_map(transformed_args) ->
        mutated = %{call | input: Map.merge(call[:input] || %{}, transformed_args)}
        {blocked, [{mutated, ctx} | allowed]}

      {:transform, _ctx} ->
        {blocked, [{call, %{}} | allowed]}

      _ ->
        classify_active_set(call, active_set, blocked, allowed)
    end
  end

  defp tool_call_hook_event(call, session_id) do
    {:tool_call,
     %{
       tool_use_id: call[:id],
       tool_name: call[:name],
       args: call[:input] || %{},
       session_id: session_id,
       parent_tool_call_id: nil
     }}
  end

  defp classify_active_set(call, active_set, blocked, allowed) do
    if active_set != nil and call[:name] not in active_set do
      {[{call, :active_set} | blocked], allowed}
    else
      {blocked, [{call, %{}} | allowed]}
    end
  end

  # Hooks cannot bypass the active set. An argument rewrite must also be
  # independently authorized: approval of the original call ID is not
  # approval of different arguments under that same ID.
  defp reject_unauthorized_rewrites(state, blocked_calls, allowed_calls_w_ctx, active_set) do
    {unauthorized, allowed_calls_w_ctx} =
      Enum.split_with(allowed_calls_w_ctx, fn {call, ctx} ->
        unauthorized_rewrite?(state, call, ctx, active_set)
      end)

    {blocked_calls ++ unauthorized_extension_blocks(unauthorized), allowed_calls_w_ctx}
  end

  defp unauthorized_rewrite?(state, call, ctx, active_set) do
    inactive? = active_set != nil and call[:name] not in active_set
    rewritten? = Map.has_key?(ctx, :args)

    policy =
      Handbeam.Permissions.ToolPolicy.from_workspace(
        state.config.working_directory,
        %{},
        state.tool_guard_session_allow || []
      )

    inactive? or (rewritten? and Handbeam.Permissions.ToolPolicy.decision(policy, call) != :auto)
  end

  defp unauthorized_extension_blocks(unauthorized) do
    Enum.map(unauthorized, fn {call, _} ->
      {call,
       {:extension, "Transformed call is not authorized by workspace permissions or active tools"}}
    end)
  end

  defp emit_allowed_tool_starts(allowed_calls_w_ctx, opts) do
    Enum.each(allowed_calls_w_ctx, fn {call, _ctx} ->
      emit(opts, :tool_start, %{
        tool_use_id: call[:id],
        tool: call[:name],
        input: redact_tool_input(call[:name], call[:input] || %{}),
        parent_tool_call_id: nil
      })
    end)
  end

  defp execute_or_skip_blocked_tools(state, [], denied_blocks, opts) do
    result_msg = Message.tool_results(Enum.reverse(denied_blocks))

    state
    |> State.append_messages([result_msg])
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(opts, :steer)
    |> do_turn(opts)
  end

  defp execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts) do
    t0 = System.monotonic_time(:millisecond)

    case execute_tool_calls_with_guard_results(allowed_calls, state) do
      {:ok, result_msg, ui_blocks} ->
        finish_allowed_tool_execution(%{
          state: state,
          allowed_calls: allowed_calls,
          result_msg: result_msg,
          ui_blocks: ui_blocks,
          denied_blocks: denied_blocks,
          opts: opts,
          t0: t0
        })
    end
  end

  defp finish_allowed_tool_execution(execution) do
    duration_ms = System.monotonic_time(:millisecond) - execution.t0

    Logger.debug(
      "[Turn] tool execution complete count=#{length(execution.allowed_calls)} duration_ms=#{duration_ms}"
    )

    emit_executed_tool_ends(
      execution.state,
      execution.allowed_calls,
      execution.ui_blocks,
      execution.opts,
      duration_ms
    )

    merged_msg = %{
      execution.result_msg
      | content:
          Enum.map(execution.ui_blocks ++ execution.denied_blocks, &Executor.strip_details/1)
    }

    execution.state
    |> State.append_messages([merged_msg])
    |> Map.update!(:messages, &Handbeam.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(execution.opts, :steer)
    |> do_turn(execution.opts)
  end

  defp emit_executed_tool_ends(state, allowed_calls, ui_blocks, opts, duration_ms) do
    ui_block_by_id = Map.new(ui_blocks, fn block -> {block[:tool_use_id], block} end)

    Enum.each(allowed_calls, fn call ->
      ui_block = Map.get(ui_block_by_id, call[:id])
      record_tool_receipt(state, call, ui_block)
      emit(opts, :tool_end, executed_tool_end_payload(call, ui_block, duration_ms))
    end)
  end

  defp executed_tool_end_payload(call, ui_block, duration_ms) do
    details = (ui_block && ui_block[:details]) || %{}

    payload = %{
      tool_use_id: call[:id],
      tool: call[:name],
      parent_tool_call_id: nil,
      duration_ms: duration_ms,
      details: bounded_tool_details(details),
      file_path: tool_end_file_path(details, call),
      images: Handbeam.Tool.Images.project(ui_block && ui_block[:images]),
      output: bounded_tool_output(ui_block && ui_block[:content])
    }

    if ui_block && ui_block[:is_error] do
      Map.put(payload, :error, bounded_tool_error(ui_block[:content]))
    else
      payload
    end
  end

  defp tool_end_file_path(details, call) do
    Handbeam.Utils.SafeMap.get_first_truthy(details, :file_path, "file_path") ||
      get_in(call, [:input, :file_path]) ||
      get_in(call, [:input, "file_path"])
  end

  defp execute_tool_calls_with_guard_results(
         tool_calls,
         %State{tool_guard_result_blocks: []} = state
       ) do
    Executor.execute_all_with_details(tool_calls, state)
  end

  defp execute_tool_calls_with_guard_results(
         tool_calls,
         %State{tool_guard_result_blocks: denied_blocks} = state
       )
       when is_list(denied_blocks) do
    denied_ids = MapSet.new(Enum.map(denied_blocks, &(&1[:tool_use_id] || &1["tool_use_id"])))
    executable_calls = Enum.reject(tool_calls, &MapSet.member?(denied_ids, &1[:id]))

    with {:ok, result_msg, ui_blocks} <-
           Executor.execute_all_with_details(executable_calls, state) do
      all_ui_blocks = order_guarded_blocks(tool_calls, ui_blocks ++ denied_blocks)

      {:ok, %{result_msg | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)},
       all_ui_blocks}
    end
  end

  defp order_guarded_blocks(tool_calls, blocks) do
    by_id = Map.new(blocks, fn block -> {block[:tool_use_id] || block["tool_use_id"], block} end)
    Enum.map(tool_calls, &Map.fetch!(by_id, &1[:id]))
  end

  defp build_provider_config(%State{config: config, provider_state: provider_state}) do
    config.provider_config
    |> Map.put(:model, config.model)
    |> Map.put(:system_prompt, config.system_prompt)
    |> Map.put(:provider_state, provider_state)
    |> Map.put(:working_directory, config.working_directory)
    |> maybe_put_context(config)
    |> apply_reasoning_level(config)
  end

  defp maybe_require_final_answer(provider_config, false), do: provider_config

  defp maybe_require_final_answer(provider_config, true) do
    prompt = Map.get(provider_config, :system_prompt) || ""

    Map.put(
      provider_config,
      :system_prompt,
      String.trim_trailing(prompt) <> "\n\n" <> @final_turn_prompt
    )
  end

  defp apply_reasoning_level(provider_config, config) do
    model_entry =
      case Map.get(provider_config, :model_meta) do
        meta when is_map(meta) and map_size(meta) > 0 ->
          meta
          |> Map.put_new("id", config.model)
          |> Map.put_new(:provider, Map.get(provider_config, :provider))
          |> Map.put_new(:provider_id, Map.get(provider_config, :provider_key))
          |> Map.put_new(:api, Map.get(provider_config, :api))

        _ ->
          %{
            id: config.model,
            provider: Map.get(provider_config, :provider),
            provider_id: Map.get(provider_config, :provider_key),
            api: Map.get(provider_config, :api)
          }
      end

    Reasoning.apply_provider_options(provider_config, model_entry, config.reasoning_level)
  end

  defp maybe_put_context(provider_config, config) do
    context = config.context || %{}

    provider_config
    |> maybe_put(:conversation_id, context[:conversation_id])
    |> maybe_put(:run_id, context[:run_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp bounded_tool_output(output) when is_binary(output),
    do: String.slice(output, 0, @max_tool_event_output)

  defp bounded_tool_output(output), do: Handbeam.JsonSafe.normalize(output)

  defp bounded_tool_error(error) when is_binary(error),
    do: String.slice(error, 0, @max_tool_event_output)

  defp bounded_tool_error(error), do: error

  defp bounded_tool_details(details) do
    Handbeam.Agent.Tool.ResultContract.project_details(details || %{})
  end

  defp record_tool_receipt(state, call, ui_block) do
    conversation_id = state.config.context[:conversation_id]
    call_id = call[:id]

    if is_binary(conversation_id) and is_binary(call_id) do
      details = (ui_block && ui_block[:details]) || %{}
      side_effect = details[:side_effect] || details["side_effect"] || :unknown

      Handbeam.Agent.OperationReceipt.reserve(
        {:tool_effect, conversation_id},
        call_id,
        Handbeam.Agent.OperationReceipt.fingerprint({call[:name], side_effect})
      )

      Handbeam.Agent.OperationReceipt.complete(
        {:tool_effect, conversation_id},
        call_id,
        %{
          "tool" => call[:name],
          "side_effect" => to_string(side_effect),
          "operation_id" => details[:operation_id] || details["operation_id"]
        }
      )
    end

    :ok
  end

  # ── Error formatting ──

  defp uncertain_cursor_error?(reason) when is_binary(reason) do
    String.contains?(reason, "not retrying because execution may have started")
  end

  defp uncertain_cursor_error?(_), do: false

  defp prompt_too_long?(reason) when is_binary(reason) do
    String.contains?(reason, "context_length_exceeded") or
      String.contains?(reason, "maximum context length") or
      String.contains?(reason, "Prompt is too long") or
      String.contains?(reason, "prompt too long")
  end

  defp prompt_too_long?(_), do: false

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)

  # Auth failures otherwise look like the conversation model failed. Name the
  # provider, subscription, and model that actually made the request.
  defp format_provider_error(provider_config, reason) do
    message = format_error(reason)

    if auth_failure?(message) do
      prefix = auth_failure_prefix(provider_config)
      if prefix == "", do: message, else: "#{prefix}: #{message}"
    else
      message
    end
  end

  defp auth_failure?(message) when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "oauth") or
      String.contains?(downcased, "access token") or
      String.contains?(downcased, "authorization") or
      String.contains?(downcased, "unauthor") or
      String.contains?(downcased, "sign in") or
      String.contains?(message, "订阅") or
      String.contains?(message, "授权") or
      String.contains?(message, "重新登录") or
      String.contains?(message, "重新连接")
  end

  defp auth_failure?(_), do: false

  defp auth_failure_prefix(provider_config) when is_map(provider_config) do
    provider_id = provider_config[:provider_key] || provider_config[:provider]
    model = provider_config[:model]

    [subscription_label(provider_id), model_label(provider_id, model)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp auth_failure_prefix(_), do: ""

  defp subscription_label(provider_id) when is_binary(provider_id) do
    case Handbeam.Agent.Auth.Subscriptions.get(provider_id) do
      {:ok, %{login_label: label}} when is_binary(label) and label != "" -> label
      _ -> provider_id
    end
  end

  defp subscription_label(provider_id) when is_atom(provider_id) and not is_nil(provider_id) do
    subscription_label(Atom.to_string(provider_id))
  end

  defp subscription_label(_), do: nil

  defp model_label(_provider_id, model) when is_binary(model) and model != "", do: model
  defp model_label(_provider_id, _), do: nil

  defp redact_tool_input("browser", input) when is_map(input) do
    input = Handbeam.Log.Redactor.redact(input)
    args = Map.get(input, "args") || Map.get(input, :args)

    if is_list(args) do
      redacted = Handbeam.Browser.Redactor.redact_args(args)

      input
      |> Map.put("args", redacted)
      |> Map.delete(:args)
    else
      input
    end
  end

  defp redact_tool_input(_name, input), do: Handbeam.Log.Redactor.redact(input)
end
