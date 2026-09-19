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
  def force_compact(%State{} = state) do
    compact_messages_in_state(state, state.messages)
  end

  @spec maybe_compact(State.t()) :: {:compacted | :unchanged, State.t()}
  def maybe_compact(%State{config: config, messages: messages} = state) do
    reserve_tokens = (config.compaction && config.compaction.reserve_tokens) || 16_384
    max_tokens = config.max_tokens || 200_000

    if estimate_messages_tokens(messages) <= max_tokens - reserve_tokens do
      {:unchanged, state}
    else
      {:compacted, compact_messages_in_state(state, messages)}
    end
  end

  defp compact_messages_in_state(%State{} = state, messages) do
    keep_recent_tokens =
      (state.config.compaction && state.config.compaction.keep_recent_tokens) || 20_000

    case prepare_summary_compaction(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)

        case summarize_compaction(prepared, state) do
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

  defp summarize_compaction(prepared, %State{} = state) do
    provider = state.config.provider

    config =
      state.config.provider_config
      |> Map.delete(:provider_state)
      |> Map.delete("provider_state")
      |> Map.put(:system_prompt, @summary_system_prompt)

    prompt = build_summary_prompt(prepared.messages_to_summarize, prepared.previous_summary)

    with {:ok, response} <- provider.complete([Message.user(prompt)], [], config),
         {:ok, summary_text} <- extract_summary_text(response) do
      {:ok, summary_text}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp build_summary_prompt(messages_to_summarize, previous_summary) do
    previous_summary_section =
      case previous_summary do
        nil ->
          ""

        %Message{} = message ->
          "<previous-summary>\n#{summary_body(message)}\n</previous-summary>\n\n"
      end

    """
    #{previous_summary_section}<conversation>
    #{serialize_messages(messages_to_summarize)}
    </conversation>

    #{@summary_prompt}
    """
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

  defp summary_body(%Message{content: content}) when is_binary(content) do
    content
    |> String.replace_prefix(@summary_prefix, "")
    |> String.trim()
  end

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
          %{block | content: "[compacted]"}

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
    blocks
    |> Enum.map_join("\n", &inspect/1)
    |> String.length()
    |> then(&max(1, div(&1, 4)))
  end

  defp estimate_message_tokens(_), do: 1

  defp serialize_messages(messages) do
    messages
    |> Enum.map(&serialize_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    "[#{role_label(role)}]\n#{content}"
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(&serialize_block(role, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp serialize_block(role, %{type: "text", text: text}) when is_binary(text) do
    "[#{role_label(role)}]\n#{text}"
  end

  defp serialize_block(:assistant, %{type: type, name: name, input: input})
       when type in ["tool_use", "server_tool_use"] do
    "[Assistant tool call] #{name}(#{inspect(input)})"
  end

  defp serialize_block(_role, %{type: type, content: content})
       when type in ["tool_result", "server_tool_result"] do
    "[Tool result]\n#{content}"
  end

  defp serialize_block(role, block) do
    "[#{role_label(role)} block #{Map.get(block, :type, "unknown")}]\n#{inspect(block)}"
  end

  defp role_label(:user), do: "User"
  defp role_label(:assistant), do: "Assistant"
  defp role_label(other), do: to_string(other)

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
