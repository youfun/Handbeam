defmodule Handbeam.Agent.TranscriptPersistence do
  @moduledoc """
  Persists runtime events into the cross-channel conversation transcript.

  This module is runtime-side, not UI-side. LiveView, SNS, webhook, CLI, and
  future channels should all be able to recover conversation history from the
  transcript without needing a LiveView process to have been alive.
  """

  require Logger

  @assistant_completed_patch %{"status" => "completed"}

  @spec append_inbound(String.t(), String.t() | Handbeam.Agent.Message.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def append_inbound(conversation_id, content, opts)
      when is_binary(conversation_id) and is_list(opts) do
    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => Keyword.get(opts, :transcript_id) || unique_id("msg-user"),
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "direction" => "inbound",
        "content" => message_text(content),
        "attachments" => persistable_attachments(content, opts),
        "raw_content" => persistable_raw_content(content, opts),
        "inbound_id" => Keyword.get(opts, :inbound_id) || Keyword.get(opts, :transcript_id)
      })
      |> put_inbound_delivery(opts)

    Handbeam.ConversationTranscriptStore.append(conversation_id, entry, opts)
  end

  @spec handle_event(String.t(), {atom(), map()}, keyword()) :: :ok
  def handle_event(conversation_id, event, opts \\ [])

  def handle_event(conversation_id, {:run_start, payload}, opts)
      when is_binary(conversation_id) do
    Process.put(assistant_key(conversation_id), nil)
    clear_buffer(conversation_id)
    clear_thinking_buffer(conversation_id)
    Process.put(run_opts_key(conversation_id), opts)
    Process.put(run_payload_key(conversation_id), payload)
    Logger.debug("[TranscriptPersistence] run_start conversation=#{conversation_id}")
    :ok
  end

  def handle_event(conversation_id, {:message_delta, %{chunk: chunk}}, _opts)
      when is_binary(conversation_id) and is_binary(chunk) and chunk != "" do
    {thinking_text, clean_chunk, new_buffer} =
      Handbeam.Agent.ThinkingFilter.strip(thinking_buffer(conversation_id), chunk)

    put_thinking_buffer(conversation_id, new_buffer)
    append_thinking(conversation_id, thinking_text)
    append_to_buffer(conversation_id, clean_chunk)
    :ok
  end

  # Explicit handler for thinking_delta: don't flush (unlike the catch-all).
  # thinking_delta is a high-frequency streaming event emitted by Anthropic
  # and StepFun providers during extended thinking. It should not trigger
  # transcript writes — the thinking buffer accumulates alongside assistant
  # text and is flushed at the next message boundary.
  def handle_event(conversation_id, {:thinking_delta, _payload}, _opts)
      when is_binary(conversation_id) do
    :ok
  end

  def handle_event(conversation_id, {:tool_start, payload}, opts)
      when is_binary(conversation_id) do
    flush(conversation_id, opts)
    finalize_assistant(conversation_id, "commentary", opts)
    Process.put(assistant_key(conversation_id), nil)

    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)
    add_running_tool(conversation_id, tool_use_id, tool_name)

    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, tool_name),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "tool_use_id" => tool_use_id,
        "tool" => tool_name,
        "tool_name" => tool_name,
        "status" => "running",
        "tool_status" => "running",
        "input" => Handbeam.Log.Redactor.redact(payload_value(payload, :input, %{})),
        "started_at" => now_iso8601()
      })

    append_or_update(conversation_id, entry, opts)
    :ok
  end

  def handle_event(conversation_id, {:tool_end, payload}, opts) when is_binary(conversation_id) do
    flush(conversation_id, opts)

    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)
    remove_running_tool(conversation_id, tool_use_id)
    error = payload_value(payload, :error)
    status = tool_status(payload, error)
    details = payload |> payload_value(:details, %{}) |> Handbeam.JsonSafe.normalize()
    output = payload |> payload_value(:output) |> Handbeam.JsonSafe.normalize()

    patch = %{
      "tool" => tool_name,
      "tool_name" => tool_name,
      "status" => status,
      "tool_status" => status,
      "duration_ms" => payload_value(payload, :duration_ms),
      "tool_duration_ms" => payload_value(payload, :duration_ms),
      "error" => error,
      "tool_error" => error,
      "output" => output,
      "details" => details,
      "file_path" => payload_value(payload, :file_path) || map_value(details, :file_path),
      "diff_lines" => map_value(details, :diff_lines)
    }

    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, tool_name),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "tool_use_id" => tool_use_id
      })
      |> Map.merge(patch)

    append_or_update(conversation_id, entry, opts)
    :ok
  end

  def handle_event(conversation_id, {:run_end, payload}, opts) when is_binary(conversation_id) do
    flush(conversation_id, opts)
    finalize_assistant(conversation_id, "final", opts)

    run_error = payload_value(payload, :error)

    cond do
      cancelled_run?(payload) ->
        case cancel_running_tools(conversation_id, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[TranscriptPersistence] cancel_running_tools failed conversation=#{conversation_id} " <>
                "reason=#{inspect(reason)}"
            )
        end

      is_nil(run_error) ->
        :ok

      true ->
        # Mark unfinished tools as error before writing the system error entry
        mark_running_tools_as_error(conversation_id, opts)

        entry =
          base_entry(conversation_id, opts)
          |> Map.merge(%{
            "id" => unique_id("msg-system"),
            "content_type" => "system_msg",
            "message_type" => "error",
            "role" => "system",
            "direction" => "outbound",
            "content" => "Run error: #{run_error}",
            "status" => "final"
          })

        {:ok, saved} = Handbeam.ConversationTranscriptStore.append(conversation_id, entry, opts)
        deliver(saved, opts)
    end

    Process.put(assistant_key(conversation_id), nil)
    clear_buffer(conversation_id)
    clear_thinking_buffer(conversation_id)
    clear_running_tools(conversation_id)
    Process.delete(run_opts_key(conversation_id))
    Process.delete(run_payload_key(conversation_id))
    Logger.debug("[TranscriptPersistence] run_end conversation=#{conversation_id}")
    :ok
  end

  def handle_event(conversation_id, _event, opts) when is_binary(conversation_id) do
    flush(conversation_id, opts)
    :ok
  end

  def handle_event(_conversation_id, _event, _opts), do: :ok

  @doc """
  Marks durable in-flight tools for this conversation+run as cancelled.

  Scans the transcript store rather than the agent-task process dictionary, so
  Runner can seal a killed run before broadcasting `run_end`. Terminal tool
  statuses and other runs are left unchanged. `:interrupted` is not cancel.
  """
  @spec cancel_running_tools(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_running_tools(conversation_id, opts \\ []) when is_binary(conversation_id) do
    run_id = Keyword.get(opts, :run_id)

    cond do
      blank?(run_id) ->
        Logger.error(
          "[TranscriptPersistence] cancel_running_tools missing run_id conversation=#{conversation_id}"
        )

        {:error, :missing_run_id}

      true ->
        case Handbeam.ConversationTranscriptStore.list(conversation_id, opts) do
          {:ok, entries} ->
            patch_running_tools_cancelled(conversation_id, entries, run_id, opts)

          {:error, reason} ->
            Logger.error(
              "[TranscriptPersistence] cancel_running_tools list failed conversation=#{conversation_id} " <>
                "reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp append_or_update(conversation_id, %{"id" => id} = entry, opts) do
    case Handbeam.ConversationTranscriptStore.update(conversation_id, id, entry, opts) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :not_found} ->
        Handbeam.ConversationTranscriptStore.append(conversation_id, entry, opts)

      {:error, reason} ->
        Logger.warning(fn ->
          "[TranscriptPersistence] failed to update transcript entry conversation=#{conversation_id} " <>
            "id=#{id} reason=#{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  defp buffer_key(conversation_id), do: {__MODULE__, :buffer, conversation_id}
  defp last_flush_key(conversation_id), do: {__MODULE__, :last_flush, conversation_id}
  defp thinking_buffer_key(conversation_id), do: {__MODULE__, :thinking_buffer, conversation_id}
  defp thinking_key(conversation_id), do: {__MODULE__, :thinking, conversation_id}
  defp assistant_key(conversation_id), do: {__MODULE__, :assistant_entry_id, conversation_id}
  defp run_opts_key(conversation_id), do: {__MODULE__, :run_opts, conversation_id}
  defp run_payload_key(conversation_id), do: {__MODULE__, :run_payload, conversation_id}
  defp running_tools_key(conversation_id), do: {__MODULE__, :running_tools, conversation_id}

  # ── Running tools tracking (for crash recovery) ──

  defp add_running_tool(conversation_id, tool_use_id, tool_name) do
    tools = Process.get(running_tools_key(conversation_id), %{})
    Process.put(running_tools_key(conversation_id), Map.put(tools, tool_use_id, tool_name))
  end

  defp remove_running_tool(conversation_id, tool_use_id) do
    case Process.get(running_tools_key(conversation_id)) do
      nil -> :ok
      tools -> Process.put(running_tools_key(conversation_id), Map.delete(tools, tool_use_id))
    end
  end

  defp clear_running_tools(conversation_id) do
    Process.delete(running_tools_key(conversation_id))
  end

  defp patch_running_tools_cancelled(conversation_id, entries, run_id, opts) do
    errors =
      entries
      |> Enum.filter(&running_tool_for_run?(&1, conversation_id, run_id))
      |> Enum.reduce([], fn entry, acc ->
        id = Map.get(entry, "id") || Map.get(entry, :id)

        cond do
          not is_binary(id) ->
            Logger.warning(fn ->
              "[TranscriptPersistence] cancel_running_tools missing entry id conversation=#{conversation_id}"
            end)

            [{:invalid_entry_id, id} | acc]

          true ->
            case Handbeam.ConversationTranscriptStore.update(
                   conversation_id,
                   id,
                   %{"status" => "cancelled", "tool_status" => "cancelled"},
                   opts
                 ) do
              {:ok, _} ->
                acc

              {:error, :not_found} ->
                Logger.warning(fn ->
                  "[TranscriptPersistence] cancel_running_tools entry vanished conversation=#{conversation_id} " <>
                    "id=#{inspect(id)}"
                end)

                acc

              {:error, reason} ->
                Logger.warning(fn ->
                  "[TranscriptPersistence] cancel_running_tools update failed conversation=#{conversation_id} " <>
                    "id=#{inspect(id)} reason=#{inspect(reason)}"
                end)

                [reason | acc]
            end
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, {:cancel_running_tools, Enum.reverse(errors)}}
    end
  end

  defp running_tool_for_run?(entry, conversation_id, run_id) do
    tool_entry?(entry) and
      same_conversation?(entry, conversation_id) and
      same_run?(entry, run_id) and
      running_tool_status?(Handbeam.TranscriptEntry.tool_status(entry))
  end

  defp tool_entry?(entry) when is_map(entry) do
    entry["content_type"] == "tool" or entry["message_type"] == "tool" or
      entry["role"] == "tool"
  end

  defp tool_entry?(_entry), do: false

  defp same_conversation?(entry, conversation_id) do
    case Map.get(entry, "conversation_id") || Map.get(entry, :conversation_id) do
      nil -> true
      id -> to_string(id) == to_string(conversation_id)
    end
  end

  defp same_run?(entry, run_id) do
    entry_run = Map.get(entry, "run_id") || Map.get(entry, :run_id)
    not blank?(entry_run) and to_string(entry_run) == to_string(run_id)
  end

  defp running_tool_status?(status) when status in [:running, "running"], do: true
  defp running_tool_status?(_status), do: false

  defp cancelled_run?(payload) do
    payload_value(payload, :status) in [:cancelled, "cancelled"]
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp mark_running_tools_as_error(conversation_id, opts) do
    case Process.get(running_tools_key(conversation_id)) do
      nil ->
        :ok

      tools when map_size(tools) == 0 ->
        :ok

      tools ->
        Enum.each(tools, fn {tool_use_id, tool_name} ->
          entry_id = tool_entry_id(tool_use_id, tool_name)

          Handbeam.ConversationTranscriptStore.update(
            conversation_id,
            entry_id,
            %{
              "status" => "error",
              "tool_status" => "error",
              "error" => "Run terminated before tool completed"
            },
            opts
          )
        end)

        :ok
    end
  end

  defp append_to_buffer(_conversation_id, ""), do: :ok

  defp append_to_buffer(conversation_id, chunk) do
    current = Process.get(buffer_key(conversation_id), [])
    Process.put(buffer_key(conversation_id), [chunk | current])
    :ok
  end

  defp append_thinking(_conversation_id, ""), do: :ok

  defp append_thinking(conversation_id, text) do
    current = Process.get(thinking_key(conversation_id), [])
    Process.put(thinking_key(conversation_id), [text | current])
    :ok
  end

  defp thinking_buffer(conversation_id), do: Process.get(thinking_buffer_key(conversation_id), "")

  defp put_thinking_buffer(conversation_id, buffer) do
    Process.put(thinking_buffer_key(conversation_id), buffer)
    :ok
  end

  defp clear_thinking_buffer(conversation_id) do
    Process.delete(thinking_buffer_key(conversation_id))
    Process.delete(thinking_key(conversation_id))
    :ok
  end

  defp take_buffer(conversation_id) do
    case Process.delete(buffer_key(conversation_id)) do
      nil -> ""
      list when is_list(list) -> list |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp clear_buffer(conversation_id) do
    Process.delete(buffer_key(conversation_id))
    Process.delete(last_flush_key(conversation_id))
    :ok
  end

  defp flush(conversation_id, opts) do
    case take_buffer(conversation_id) do
      "" ->
        :ok

      buffered ->
        entry_id = Process.get(assistant_key(conversation_id)) || unique_id("msg-assistant")
        Process.put(assistant_key(conversation_id), entry_id)

        entry =
          base_entry(conversation_id, opts)
          |> Map.merge(%{
            "id" => entry_id,
            "content_type" => "assistant_msg",
            "message_type" => "assistant",
            "role" => "assistant",
            "direction" => "outbound",
            "content" => buffered,
            "status" => "streaming"
          })

        case persist_assistant_delta(conversation_id, entry_id, entry, buffered, opts) do
          {:ok, saved} -> deliver_delta(saved, buffered, opts)
          {:error, _reason} -> :ok
        end

        Process.put(last_flush_key(conversation_id), System.monotonic_time(:millisecond))

        Logger.debug(
          "[TranscriptPersistence] flush conversation=#{conversation_id} bytes=#{byte_size(buffered)}"
        )

        :ok
    end
  end

  defp append_patch(buffered), do: %{"$append" => buffered}

  defp persist_assistant_delta(conversation_id, entry_id, entry, buffered, opts) do
    case Handbeam.ConversationTranscriptStore.update(
           conversation_id,
           entry_id,
           %{
             "content" => append_patch(buffered),
             "status" => "streaming"
           },
           opts
         ) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :not_found} ->
        Handbeam.ConversationTranscriptStore.append(conversation_id, entry, opts)

      {:error, reason} ->
        Logger.warning(fn ->
          "[TranscriptPersistence] assistant delta persist failed conversation=#{conversation_id} " <>
            "id=#{entry_id} reason=#{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  defp base_entry(conversation_id, opts) do
    %{
      "conversation_id" => conversation_id,
      "run_id" => Keyword.get(opts, :run_id),
      "channel" => channel(opts),
      "source" => opts |> Keyword.get(:source, :unknown) |> to_string(),
      "delivery_ref" => Keyword.get(opts, :delivery_ref),
      "metadata" => transcript_metadata(opts)
    }
  end

  defp put_inbound_delivery(entry, opts) do
    delivery = inbound_delivery(opts)

    entry
    |> Map.put("delivery", delivery)
    |> Map.put("interrupts_work", delivery == "steer")
  end

  defp inbound_delivery(opts) do
    case Keyword.get(opts, :deliver_as) do
      :steer -> "steer"
      :follow_up -> "follow_up"
      :new_run -> "new_run"
      "steer" -> "steer"
      "follow_up" -> "follow_up"
      "new_run" -> "new_run"
      _ -> "new_run"
    end
  end

  defp finalize_assistant(conversation_id, phase, opts) do
    if assistant_id = Process.get(assistant_key(conversation_id)) do
      Handbeam.ConversationTranscriptStore.update(
        conversation_id,
        assistant_id,
        Map.put(@assistant_completed_patch, "phase", phase),
        opts
      )
    else
      :ok
    end
  end

  defp tool_status(payload, error) do
    case payload_value(payload, :status) do
      status when status in [:cancelled, "cancelled"] -> "cancelled"
      _status when not is_nil(error) -> "error"
      _status -> "done"
    end
  end

  defp transcript_metadata(opts) do
    opts
    |> Keyword.take([:workspace_id, :model, :source])
    |> Map.new(fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp channel(opts),
    do: opts |> Keyword.get(:channel, Keyword.get(opts, :source, :unknown)) |> to_string()

  defp deliver(entry, opts) do
    if delivery_channel?(opts) do
      Handbeam.Delivery.deliver(entry, opts)
    else
      :ok
    end
  end

  defp deliver_delta(entry, delta, opts) do
    if delivery_channel?(opts) do
      entry
      |> Map.put("delivery_delta", delta)
      |> Handbeam.Delivery.deliver(opts)
    else
      :ok
    end
  end

  defp delivery_channel?(opts) do
    Keyword.has_key?(opts, :delivery) or Keyword.get(opts, :source) in [:sns, :webhook, :cli]
  end

  defp message_text(%Handbeam.Agent.Message{} = message),
    do: Handbeam.Agent.Message.text(message) || ""

  defp message_text(content) when is_binary(content), do: content
  defp message_text(_content), do: ""

  defp persistable_attachments(_content, opts) do
    case Keyword.get(opts, :attachments) do
      list when is_list(list) and list != [] ->
        Enum.map(list, &Handbeam.Attachments.persistable/1)

      _ ->
        []
    end
  end

  defp persistable_raw_content(content, opts) do
    attachments = persistable_attachments(content, opts)

    cond do
      attachments != [] ->
        %{
          "text" => message_text(content),
          "attachments" => attachments
        }

      match?(%Handbeam.Agent.Message{content: list} when is_list(list), content) ->
        content.content
        |> Enum.map(&sanitize_block/1)
        |> stringify_value()

      true ->
        content
    end
  end

  defp sanitize_block(block) when is_map(block) do
    block
    |> stringify_value()
    |> Map.drop(["data", "uri"])
  end

  defp sanitize_block(block), do: block

  defp payload_value(payload, key, default \\ nil)

  defp payload_value(payload, key, default) when is_map(payload) and is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))
  end

  defp payload_value(_payload, _key, default), do: default

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp stringify_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp tool_entry_id(tool_use_id, tool_name) do
    if is_binary(tool_use_id) and tool_use_id != "" do
      "tool-#{tool_use_id}"
    else
      "tool-event-#{tool_name}"
    end
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
