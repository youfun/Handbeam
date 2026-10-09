defmodule Handbeam.Agent.Compactor do
  @moduledoc """
  Context compaction — summarizes older conversation history when approaching
  token limits, with fallback truncation.
  """

  alias Handbeam.Agent.{Message, State}

  require Logger

  @default_keep_recent 10
  @truncate_length 200
  @summary_prefix "Previous analysis summary (from earlier in this session):"

  @summary_system_prompt """
  You are performing CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

  Include:
  - Current progress and key decisions made
  - Important context, constraints, or user preferences
  - What remains to be done (clear next steps)
  - Any critical data, examples, or references needed to continue

  Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
  """

  @summary_prompt """
  Create a structured handoff summary for another language model that will resume this task.

  Use this EXACT structure:

  ## Goal
  [What the user is trying to accomplish]

  ## Constraints & Preferences
  - [Important constraints, preferences, or requirements]

  ## Progress
  ### Done
  - [Completed tasks, findings, or verified facts]

  ### In Progress
  - [Current work that is not finished yet]

  ### Blocked
  - [Active blockers or "(none)"]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Evidence & References
  - [Evidence chains, exact file paths, tool names, function names, or error messages]

  ## Next Steps
  1. [Ordered next action]

  ## Critical Context
  - [Anything the next model must preserve exactly]
  """

  @spec summary_prefix() :: String.t()
  def summary_prefix, do: @summary_prefix

  @doc """
  Compact context if message tokens exceed threshold.
  Returns `{:compacted, state}` or `{:unchanged, state}`.
  """
  @spec force_compact(State.t()) :: State.t()
  def force_compact(%State{} = state, opts \\ []) do
    compact_messages_in_state(state, state.messages, opts)
  end

  @spec maybe_compact(State.t(), keyword()) :: {:compacted | :unchanged, State.t()}
  def maybe_compact(%State{config: config, messages: messages} = state, opts \\ []) do
    reserve_tokens = compaction_limit(:reserve_tokens, config, 16_384)
    max_tokens = compaction_limit(:max_tokens, config, 200_000)

    if estimate_messages_tokens(messages) <= max_tokens - reserve_tokens do
      {:unchanged, state}
    else
      {:compacted, compact_messages_in_state(state, messages, opts)}
    end
  end

  defp compact_messages_in_state(%State{} = state, messages, opts) do
    keep_recent_tokens = compaction_limit(:keep_recent_tokens, state.config, 20_000)

    case prepare_summary_compaction(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)

        case summarize_compaction(prepared, state, messages, opts) do
          {:ok, summary_text} ->
            compacted = [prepared.first, build_summary_message(summary_text) | prepared.recent]
            %{state | messages: compacted}

          {:error, reason} ->
            Logger.warning(fn ->
              "summary compaction failed, falling back to truncation: #{inspect(reason)}"
            end)

            fallback_compact_state(state, messages)
        end

      :noop ->
        fallback_compact_state(state, messages)
    end
  end

  defp fallback_compact_state(%State{} = state, messages) do
    keep_recent = min(@default_keep_recent, max(1, length(messages) - 2))
    %{state | messages: compact_messages(messages, keep_recent: keep_recent)}
  end

  defp prepare_summary_compaction([first | rest], keep_recent_tokens) do
    {previous_summary, tail} = pop_existing_summary(rest)

    if tail == [] do
      :noop
    else
      cut_index = find_cut_point(tail, keep_recent_tokens)
      messages_to_summarize = Enum.take(tail, cut_index)
      recent = Enum.drop(tail, cut_index)

      if messages_to_summarize == [] do
        :noop
      else
        {:ok,
         %{
           first: first,
           previous_summary: previous_summary,
           messages_to_summarize: messages_to_summarize,
           recent: recent
         }}
      end
    end
  end

  defp prepare_summary_compaction(_, _keep_recent_tokens), do: :noop

  defp summarize_compaction(_prepared, %State{} = state, messages, opts) do
    provider = state.config.provider
    tool_defs = Keyword.get(opts, :tool_defs, [])
    {request_messages, suffix_count} = append_compaction_suffix(messages)

    config =
      opts
      |> Keyword.get(:provider_config, state.config.provider_config)
      |> Map.delete(:provider_state)
      |> Map.delete("provider_state")
      |> Map.put(:system_prompt, state.config.system_prompt)
      |> Map.put(:cache_fork, true)
      |> Map.put(:cache_fork_suffix, suffix_count)

    Logger.warning(
      "[Compactor] summary_request system_prompt=parent tools=#{length(tool_defs)} " <>
        "messages=#{length(request_messages)} serialized=false"
    )

    with {:ok, response} <- provider.complete(request_messages, tool_defs, config),
         :ok <- log_summary_usage(response),
         :ok <- reject_tool_calls(response),
         {:ok, summary_text} <- extract_summary_text(response) do
      {:ok, summary_text}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp append_compaction_suffix(messages) do
    instruction = Message.user(compaction_instruction())

    case List.last(messages) do
      %Message{role: :assistant} ->
        {messages ++ [instruction], 1}

      _ ->
        {messages ++ [Message.assistant("Continuing."), instruction], 2}
    end
  end

  defp compaction_instruction do
    """
    #{@summary_system_prompt}
    Do not call tools. Reply with the handoff summary only.

    #{@summary_prompt}
    """
  end

  defp reject_tool_calls(%{messages: messages}) when is_list(messages) do
    if Enum.any?(messages, &tool_call_message?/1),
      do: {:error, :summary_tool_call},
      else: :ok
  end

  defp reject_tool_calls(_response), do: :ok

  defp tool_call_message?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_use", "server_tool_use"] -> true
      _ -> false
    end)
  end

  defp tool_call_message?(_message), do: false

  defp compaction_limit(:max_tokens, config, default) do
    env_positive("HANDBEAM_COMPACTION_MAX_TOKENS") || config.max_tokens || default
  end

  defp compaction_limit(:reserve_tokens, config, default) do
    env_positive("HANDBEAM_COMPACTION_RESERVE_TOKENS") ||
      (config.compaction && config.compaction.reserve_tokens) || default
  end

  defp compaction_limit(:keep_recent_tokens, config, default) do
    env_positive("HANDBEAM_COMPACTION_KEEP_RECENT_TOKENS") ||
      (config.compaction && config.compaction.keep_recent_tokens) || default
  end

  defp env_positive(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp log_summary_usage(%{usage: usage}) when is_map(usage) do
    Logger.warning(
      "[Compactor] summary_usage input=#{usage_num(usage, :input_tokens)} " <>
        "total_input=#{usage_num(usage, :total_input_tokens)} " <>
        "cache_read=#{usage_num(usage, :cache_read_input_tokens)} " <>
        "cache_write=#{usage_num(usage, :cache_creation_input_tokens)} " <>
        "output=#{usage_num(usage, :output_tokens)}"
    )

    :ok
  end

  defp log_summary_usage(_response), do: :ok

  defp usage_num(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
  end

  defp extract_summary_text(%{messages: messages}) when is_list(messages) do
    summary_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :assistant} = message ->
          case Message.text(message) |> String.trim() do
            "" -> nil
            text -> text
          end

        _ ->
          nil
      end)

    if summary_text, do: {:ok, summary_text}, else: {:error, :empty_summary}
  end

  defp extract_summary_text(_response), do: {:error, :invalid_summary_response}

  defp build_summary_message(summary_text) do
    %Message{role: :user, content: "#{@summary_prefix}\n#{String.trim(summary_text)}"}
  end

  defp pop_existing_summary([message | rest]) do
    if summary_message?(message), do: {message, rest}, else: {nil, [message | rest]}
  end

  defp pop_existing_summary([]), do: {nil, []}

  defp summary_message?(%Message{role: :user, content: content}) when is_binary(content) do
    String.starts_with?(content, @summary_prefix)
  end

  defp summary_message?(_message), do: false

  @spec compact_messages([Message.t()], keyword()) :: [Message.t()]
  def compact_messages(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    count = length(messages)

    if count <= keep_recent + 1 do
      messages
    else
      [first | rest] = messages
      {middle, recent} = Enum.split(rest, max(length(rest) - keep_recent, 0))
      compacted_middle = Enum.map(middle, &compact_message/1)
      [first | compacted_middle] ++ recent
    end
  end

  defp compact_message(%Message{content: blocks} = msg) when is_list(blocks) do
    compacted_blocks =
      Enum.map(blocks, fn
        %{type: type} = block when type in ["tool_result", "server_tool_result"] ->
          %{block | content: "[compacted; old observations are not actionable]"}
          |> Map.delete(:images)

        %{type: "thinking", thinking: text} = block when byte_size(text) > @truncate_length ->
          %{block | thinking: String.slice(text, 0, @truncate_length) <> "..."}

        block ->
          block
      end)

    %{msg | content: compacted_blocks}
  end

  defp compact_message(%Message{role: :assistant, content: text} = msg) when is_binary(text) do
    if String.length(text) > @truncate_length do
      %{msg | content: String.slice(text, 0, @truncate_length) <> "..."}
    else
      msg
    end
  end

  defp compact_message(msg), do: msg

  defp find_cut_point(messages, keep_recent_tokens) when is_list(messages) and messages != [] do
    threshold_index = find_threshold_index(messages, keep_recent_tokens)

    # Pre-index to avoid O(n) Enum.at/2 calls in find loops
    indexed = Enum.with_index(messages)

    user_cut =
      indexed
      |> Enum.drop(threshold_index)
      |> Enum.find_value(fn {msg, idx} -> real_user_message?(msg) && idx end)

    assistant_cut =
      indexed
      |> Enum.drop(threshold_index)
      |> Enum.find_value(fn {msg, idx} -> assistant_message?(msg) && idx end)

    fallback_cut =
      indexed
      |> Enum.take(threshold_index + 1)
      |> Enum.reverse()
      |> Enum.find_value(fn {msg, idx} -> valid_cut_message?(msg) && idx end)

    user_cut || assistant_cut || fallback_cut || 0
  end

  defp find_cut_point(_messages, _keep_recent_tokens), do: 0

  defp find_threshold_index(messages, keep_recent_tokens) do
    max_index = length(messages) - 1

    messages
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while({0, 0}, fn {msg, rev_idx}, {_threshold_index, acc_tokens} ->
      new_acc_tokens = acc_tokens + estimate_message_tokens(msg)
      index = max_index - rev_idx

      if new_acc_tokens >= keep_recent_tokens do
        {:halt, {index, new_acc_tokens}}
      else
        {:cont, {0, new_acc_tokens}}
      end
    end)
    |> elem(0)
  end

  defp real_user_message?(%Message{role: :user} = message) do
    not tool_result_message?(message) and not summary_message?(message)
  end

  defp real_user_message?(_message), do: false

  defp assistant_message?(%Message{role: :assistant}), do: true
  defp assistant_message?(_message), do: false

  defp valid_cut_message?(message), do: real_user_message?(message) or assistant_message?(message)

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  defp estimate_messages_tokens(messages),
    do: Enum.reduce(messages, 0, &(&2 + estimate_message_tokens(&1)))

  defp estimate_message_tokens(%Message{content: content}) when is_binary(content) do
    max(1, div(String.length(content), 4))
  end

  defp estimate_message_tokens(%Message{content: blocks}) when is_list(blocks) do
    text_cost =
      blocks
      |> Enum.map_join("\n", &inspect/1)
      |> String.length()
      |> then(&max(1, div(&1, 4)))

    # Two recent images are retained on the wire. Charge their visual cost,
    # not just a few tokens of opaque reference text.
    text_cost +
      Enum.reduce(blocks, 0, fn block, cost ->
        cost + 6_000 * length(Map.get(block, :images, []))
      end)
  end

  defp estimate_message_tokens(_), do: 1

  defp fire_on_compaction(_middle, %State{config: %{on_compaction: nil}}), do: :ok

  defp fire_on_compaction(middle, %State{config: %{on_compaction: callback}} = state)
       when is_function(callback, 2) do
    callback.(middle, state)
  rescue
    e ->
      Logger.warning(fn ->
        "on_compaction callback crashed: #{Exception.message(e)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      :ok
  catch
    kind, payload ->
      Logger.warning(fn ->
        "on_compaction callback error (#{kind}): #{inspect(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      :ok
  end

  defp fire_on_compaction(_, _), do: :ok
end
