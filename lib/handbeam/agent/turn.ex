defmodule Handbeam.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Handbeam.Agent.{Compactor, Message, State}
  alias Handbeam.Agent.Middleware
  alias Handbeam.Agent.Provider.Retry
  alias Handbeam.Agent.Tool.Executor
  alias Handbeam.Extension.HookPipeline

  require Logger

  @max_tool_event_output 16_000

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
    hitl_ids = interrupt_data[:hitl_tool_call_ids] || interrupt_data["hitl_tool_call_ids"] || []

    _auto_ids =
      interrupt_data[:auto_approved_tool_call_ids] ||
        interrupt_data["auto_approved_tool_call_ids"] || []

    tool_calls = last_tool_calls_from_state(state)

    # Build decision lookup keyed by tool_call_id
    decision_by_id =
      Map.new(decisions, fn d ->
        {d["tool_call_id"] || d[:tool_call_id], d}
      end)

    # Partition HITL calls into denied vs still-executable.
    {_denied_calls, denied_blocks, remembered_overrides, denied_ids} =
      Enum.reduce(hitl_ids, {[], [], %{}, MapSet.new()}, fn call_id,
                                                            {calls, blocks, overrides, denied} ->
        call = Enum.find(tool_calls, &((&1[:id] || &1["id"]) == call_id))
        decision = Map.get(decision_by_id, call_id, %{})
        action = decision["action"] || decision[:action] || "deny"

        if to_string(action) == "approve" do
          {calls, blocks, maybe_remember_auto(overrides, decision, call), denied}
        else
          tool_name =
            (call && (call[:name] || call["name"])) || decision["tool_name"] || "unknown"

          block = denied_result_block(call_id, tool_name, action)

          new_overrides =
            if decision["remember"] || decision[:remember] do
              Map.put(overrides, tool_name, :deny)
            else
              overrides
            end

          {[call | calls], [block | blocks], new_overrides, MapSet.put(denied, call_id)}
        end
      end)

    # Approved = user-approved HITL calls + auto-approved siblings
    approved_calls =
      Enum.reject(tool_calls, fn call ->
        id = call[:id] || call["id"]
        MapSet.member?(denied_ids, id)
      end)

    # Merge remembered overrides with existing
    merged_overrides = Map.merge(state.tool_guard_overrides || %{}, remembered_overrides)

    # Clean interrupt state, set denied blocks, set overrides
    state =
      state
      |> Map.put(:status, :running)
      |> Map.put(:interrupt_data, nil)
      |> Map.put(:tool_guard_result_blocks, denied_blocks)
      |> Map.put(:tool_guard_overrides, merged_overrides)

    # Execute approved + auto-approved tool calls
    if approved_calls == [] do
      # All denied — inject denied blocks as tool_result and continue
      result_msg = Message.tool_results(denied_blocks |> Enum.reverse())

      state
      |> State.append_messages([result_msg])
      |> mw_run(:after_tool_execution)
      |> inject_candidate_messages(opts, :steer)
      |> do_turn(opts)
    else
      {executable, _already_denied} =
        Enum.split_with(approved_calls, fn call ->
          id = call[:id] || call["id"]
          not Enum.any?(denied_blocks, &((&1[:tool_use_id] || &1["tool_use_id"]) == id))
        end)

      case Executor.execute_all_with_details(executable, state) do
        {:ok, result_msg, ui_blocks} ->
          # Merge denied blocks with executed results
          all_ui_blocks = order_guarded_blocks(approved_calls, ui_blocks ++ denied_blocks)
          merged_msg = %{result_msg | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)}

          # Emit tool_end events for executed calls
          emit_tool_end_events(executable, ui_blocks, opts)

          state
          |> State.append_messages([merged_msg])
          |> mw_run(:after_tool_execution)
          |> inject_candidate_messages(opts, :steer)
          |> do_turn(opts)
      end
    end
    |> finish_run(opts)
  end

  def resume_after_tool_approval(%State{} = state, _decisions, _opts) do
    Logger.warning(
      "[Turn] resume_after_tool_approval called on non-interrupted state status=#{state.status}"
    )

    state
  end

  # ── Resume helpers ──

  defp maybe_remember_auto(overrides, decision, call) do
    if decision["remember"] || decision[:remember] do
      tool_name =
        (call && (call[:name] || call["name"])) || decision["tool_name"] || decision[:tool_name]

      if is_binary(tool_name) and tool_name != "" do
        Map.put(overrides, tool_name, :auto)
      else
        overrides
      end
    else
      overrides
    end
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
    name = call[:name] || call["name"]

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
        duration_ms: 0,
        details: details,
        file_path: file_path,
        output: bounded_tool_output(ui_block && (ui_block[:content] || ui_block["content"]))
      }

      payload =
        if ui_block && ui_block[:is_error] do
          Map.put(payload, :error, ui_block[:content])
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
      emit(opts, :run_end, %{status: :error, error: state.error, turns: 0})
      emit(opts, :agent_end, %{status: :error, error: state.error, turns: 0})
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
    payload = %{status: result.status, turns: result.turn, usage: result.usage}
    payload = if result.error, do: Map.put(payload, :error, result.error), else: payload

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

      case HookPipeline.run(session_id, {:before_agent_start, payload}) do
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

      case HookPipeline.run(session_id, {:context, payload}) do
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

  defp empty_visible_end_turn?(messages) do
    assistant_messages = Enum.filter(messages, &match?(%Message{role: :assistant}, &1))

    assistant_messages != [] and
      Enum.all?(assistant_messages, fn message ->
        not visible_assistant_text?(message) and Message.tool_calls(message) == []
      end)
  end

  defp visible_assistant_text?(%Message{} = message) do
    case Message.text(message) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  # ── Turn loop ──

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
    provider = state.config.provider
    provider_config = build_provider_config(state)

    streaming? = Keyword.get(opts, :streaming, false)

    chunk_tracker = if streaming?, do: :counters.new(1, []), else: nil

    streamed_text_tracker =
      if streaming?, do: Agent.start_link(fn -> "" end) |> elem(1), else: nil

    on_chunk =
      cond do
        is_function(Keyword.get(opts, :on_chunk), 1) ->
          user_on_chunk = Keyword.fetch!(opts, :on_chunk)

          fn chunk ->
            track_chunk(chunk_tracker, chunk)
            track_streamed_text(streamed_text_tracker, chunk)
            # Logger.debug("[Turn] streaming chunk -> user_on_chunk #{log_chunk(chunk)}")
            user_on_chunk.(chunk)
          end

        streaming? ->
          fn chunk ->
            track_chunk(chunk_tracker, chunk)
            track_streamed_text(streamed_text_tracker, chunk)
            # Logger.debug("[Turn] streaming chunk -> message_delta #{log_chunk(chunk)}")
            emit(opts, :message_delta, %{chunk: chunk})
          end

        true ->
          nil
      end

    provider_config =
      provider_config
      |> Map.put(:stream, streaming?)
      |> maybe_put_provider_event_callback(opts)
      |> then(fn pc ->
        if is_function(on_chunk, 1), do: Map.put(pc, :on_chunk, on_chunk), else: pc
      end)

    tool_defs =
      Keyword.get(opts, :session_id)
      |> case do
        nil -> Handbeam.Tool.Registry.tool_defs()
        sid -> Handbeam.Tool.Registry.tool_defs_for_session(sid)
      end

    # context hook — extensions can filter/modify messages and system_prompt
    # for this provider call only (does NOT modify persistent state/transcript)
    {outbound_messages, provider_config} = apply_context_hook(state, provider_config, opts)

    Logger.debug(
      "[Turn] provider call provider=#{inspect(provider)} streaming=#{streaming?} " <>
        "tool_defs=#{length(tool_defs)} messages=#{length(outbound_messages)}"
    )

    provider_t0 = System.monotonic_time(:millisecond)

    {provider_result, streamed_text} =
      try do
        result =
          call_provider_with_retry(
            provider,
            state,
            outbound_messages,
            tool_defs,
            provider_config,
            streaming?,
            on_chunk,
            chunk_tracker
          )

        {result, take_streamed_text(streamed_text_tracker)}
      after
        stop_streamed_text_tracker(streamed_text_tracker)
      end

    case provider_result do
      {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage} = response} ->
        Logger.debug(
          "[Turn] provider returned tool_use new_msgs=#{length(new_msgs)} " <>
            "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0}"
        )

        state =
          state
          |> State.append_messages(new_msgs)
          |> State.increment_turn()
          |> State.merge_usage(usage)
          |> State.merge_provider_state(Map.get(response, :provider_state, %{}))
          |> State.put_provider_response_metadata(Map.get(response, :response_metadata, %{}))

        state = mw_run(state, :after_tool_request)

        case state.status do
          :interrupted ->
            emit(opts, :tool_approval_requested, state.interrupt_data || %{})
            state

          _ ->
            handle_tool_use(state, new_msgs, opts)
        end

      {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage} = response} ->
        Logger.debug(
          "[Turn] provider returned end_turn new_msgs=#{length(new_msgs)} " <>
            "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
            "usage=#{inspect(usage)}"
        )

        state =
          state
          |> State.append_messages(new_msgs)
          |> State.increment_turn()
          |> State.merge_usage(usage)
          |> State.merge_provider_state(Map.get(response, :provider_state, %{}))
          |> State.put_provider_response_metadata(Map.get(response, :response_metadata, %{}))

        state = mw_run(state, :after_completion)

        emit_completion_messages(opts, new_msgs, streaming?, chunk_tracker, streamed_text)

        cond do
          empty_visible_end_turn?(new_msgs) and
              not Keyword.get(opts, :empty_end_turn_retried, false) ->
            Logger.warning(
              "[Turn] empty visible end_turn — retrying once " <>
                "(thinking-only or blank assistant message)"
            )

            do_turn(state, Keyword.put(opts, :empty_end_turn_retried, true))

          empty_visible_end_turn?(new_msgs) ->
            error_msg =
              "Provider ended the turn with no visible assistant response or tool call"

            Logger.warning("[Turn] #{error_msg}")

            state
            |> Map.put(:status, :error)
            |> Map.put(:error, error_msg)
            |> mw_run(:on_error)

          true ->
            continue_with_pending_or_complete(state, opts)
        end

      {:error, reason} ->
        error_msg = format_error(reason)

        if not Keyword.get(opts, :prompt_too_long_retried, false) and prompt_too_long?(error_msg) do
          Logger.info("[Turn] Prompt too long — forcing compaction and retrying")

          compacted_state = Compactor.force_compact(state)

          if compacted_state.messages == state.messages do
            state = %{state | status: :error, error: error_msg}
            mw_run(state, :on_error)
          else
            do_completion(compacted_state, Keyword.put(opts, :prompt_too_long_retried, true))
          end
        else
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
            Logger.error(
              "[Turn] Provider error provider=#{inspect(provider)} " <>
                "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
                "error=#{error_msg}"
            )

            state = %{state | status: :error, error: error_msg}
            mw_run(state, :on_error)
          end
        end
    end
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
        %{state | status: :completed}

      queue ->
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
         attempt \\ 0
       ) do
    result =
      call_provider(provider, outbound_messages, tool_defs, provider_config, streaming?, on_chunk)

    case result do
      {:error, reason} ->
        retry_config = retry_config(state, provider_config)

        case {Retry.should_retry_error?(reason, attempt, retry_config),
              chunks_emitted?(chunk_tracker)} do
          {{:retry, delay_ms}, false} ->
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
              reason
            )

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
         reason
       ) do
    Logger.warning(fn ->
      "[Turn] provider transient error, retrying attempt=#{attempt + 1} " <>
        "delay_ms=#{delay_ms} error=#{format_error(reason)}"
    end)

    Process.sleep(delay_ms)

    call_provider_with_retry(
      provider,
      state,
      outbound_messages,
      tool_defs,
      provider_config,
      streaming?,
      on_chunk,
      chunk_tracker,
      attempt + 1
    )
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
  defp track_chunk(_counter, _chunk), do: :ok

  defp track_streamed_text(nil, _chunk), do: :ok
  defp track_streamed_text(_agent, ""), do: :ok

  defp track_streamed_text(agent, chunk) when is_binary(chunk) do
    Agent.update(agent, &(&1 <> chunk))
  end

  defp track_streamed_text(_agent, _chunk), do: :ok

  defp take_streamed_text(nil), do: ""
  defp take_streamed_text(agent), do: Agent.get(agent, & &1)

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

  defp maybe_emit_streaming_completion_tail(opts, new_msgs, streamed) do
    final_text =
      new_msgs
      |> Enum.filter(&match?(%Message{role: :assistant}, &1))
      |> Enum.map_join(fn msg -> Message.text(msg) || "" end)

    cond do
      final_text == "" ->
        Logger.debug("[Turn] streaming emitted chunks but final assistant text is empty")

      streamed == final_text ->
        Logger.debug("[Turn] streaming chunks already match final assistant text; skip replay")

      String.starts_with?(final_text, streamed) ->
        tail =
          binary_part(
            final_text,
            byte_size(streamed),
            byte_size(final_text) - byte_size(streamed)
          )

        Logger.debug(
          "[Turn] streaming final assistant text extends streamed chunks; emitting tail #{log_chunk(tail)}"
        )

        emit(opts, :message_delta, %{chunk: tail})

      true ->
        Logger.debug(
          "[Turn] streaming final assistant text diverged from streamed chunks; emitting full final text"
        )

        emit(opts, :message_delta, %{chunk: final_text})
    end
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

  defp log_emit(:message_delta, %{chunk: chunk}) when is_binary(chunk) do
    # Logger.debug("[Turn] emit message_delta #{log_chunk(chunk)}")
  end

  defp log_emit(kind, payload) do
    Logger.debug("[Turn] emit #{kind} keys=#{inspect(Map.keys(payload || %{}))}")
  end

  defp log_chunk(chunk) when is_binary(chunk) do
    preview =
      chunk
      |> String.slice(0, 40)
      |> String.replace(~r/\s+/, " ")

    "bytes=#{byte_size(chunk)} preview=#{inspect(preview)}"
  end

  defp handle_tool_use(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)
    session_id = Keyword.get(opts, :session_id)

    tool_names = Enum.map(tool_calls, & &1[:name])

    Logger.debug(
      "[Turn] handle_tool_use count=#{length(tool_calls)} tools=#{inspect(tool_names)}"
    )

    # Get active set for execution-side guard
    active_set = if session_id, do: Handbeam.Tool.Registry.active_for_session(session_id)

    # Run each tool_call through extension hooks + active set guard:
    # - extensions may block/transform tools
    # - active set blocks tools not in the allowed list
    {blocked_calls, allowed_calls_w_ctx} =
      if session_id do
        Enum.reduce(tool_calls, {[], []}, fn call, {blocked, allowed} ->
          case HookPipeline.run(
                 session_id,
                 {:tool_call,
                  %{
                    tool_use_id: call[:id],
                    tool_name: call[:name],
                    args: call[:input] || %{},
                    session_id: session_id
                  }}
               ) do
            {:block, reason} ->
              {[{call, {:extension, reason}} | blocked], allowed}

            {:transform, %{args: transformed_args} = ctx} ->
              # Mutate args from transform, keep other transformed fields for context
              mutated = %{call | input: Map.merge(call[:input] || %{}, transformed_args)}
              {blocked, [{mutated, ctx} | allowed]}

            {:transform, _ctx} ->
              # Transform without args mutation — pass through as-is
              {blocked, [{call, %{}} | allowed]}

            _ ->
              # Check active set execution guard
              if active_set != nil and call[:name] not in active_set do
                {[{call, :active_set} | blocked], allowed}
              else
                {blocked, [{call, %{}} | allowed]}
              end
          end
        end)
        |> then(fn {b, a} -> {Enum.reverse(b), Enum.reverse(a)} end)
      else
        {[], Enum.map(tool_calls, &{&1, %{}})}
      end

    # Emit tool_start only for allowed (unblocked) calls
    Enum.each(allowed_calls_w_ctx, fn {call, _ctx} ->
      emit(opts, :tool_start, %{
        tool_use_id: call[:id],
        tool: call[:name],
        input: redact_tool_input(call[:name], call[:input] || %{})
      })
    end)

    # Build denied result blocks for blocked calls
    denied_blocks =
      Enum.map(blocked_calls, fn {call, block_source} ->
        blocked_tool_result_block(call, block_source)
      end)

    t0 = System.monotonic_time(:millisecond)

    allowed_calls = Enum.map(allowed_calls_w_ctx, fn {call, _ctx} -> call end)

    if allowed_calls == [] do
      # All tools blocked — inject denied blocks directly and continue
      result_msg = Message.tool_results(Enum.reverse(denied_blocks))

      state
      |> State.append_messages([result_msg])
      |> mw_run(:after_tool_execution)
      |> inject_candidate_messages(opts, :steer)
      |> do_turn(opts)
    else
      # Execute allowed calls normally, then merge denied blocks with results
      case execute_tool_calls_with_guard_results(allowed_calls, state) do
        {:ok, result_msg, ui_blocks} ->
          duration_ms = System.monotonic_time(:millisecond) - t0

          Logger.debug(
            "[Turn] tool execution complete count=#{length(allowed_calls)} duration_ms=#{duration_ms}"
          )

          all_ui_blocks = ui_blocks ++ denied_blocks

          # Build tool_use_id → ui_block lookup (only for executed calls)
          ui_block_by_id =
            Map.new(ui_blocks, fn block ->
              {block[:tool_use_id], block}
            end)

          Enum.each(allowed_calls, fn call ->
            ui_block = Map.get(ui_block_by_id, call[:id])
            details = (ui_block && ui_block[:details]) || %{}

            # Extract file_path from details or fall back to call input
            file_path =
              details[:file_path] || details["file_path"] || call[:input][:file_path] ||
                call[:input]["file_path"]

            payload = %{
              tool_use_id: call[:id],
              tool: call[:name],
              duration_ms: duration_ms,
              details: details,
              file_path: file_path,
              output: bounded_tool_output(ui_block && ui_block[:content])
            }

            # Add error if present
            payload =
              if ui_block && ui_block[:is_error] do
                Map.put(payload, :error, ui_block[:content])
              else
                payload
              end

            emit(opts, :tool_end, payload)
          end)

          # Merge denied blocks into result content
          merged_msg = %{
            result_msg
            | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)
          }

          state
          |> State.append_messages([merged_msg])
          |> mw_run(:after_tool_execution)
          |> inject_candidate_messages(opts, :steer)
          |> do_turn(opts)
      end
    end
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
  end

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp bounded_tool_output(output) when is_binary(output),
    do: String.slice(output, 0, @max_tool_event_output)

  defp bounded_tool_output(output), do: Handbeam.JsonSafe.normalize(output)

  # ── Error formatting ──

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
