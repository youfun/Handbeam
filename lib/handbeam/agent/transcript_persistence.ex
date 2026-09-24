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
        "inbound_id" => Keyword.get(opts, :inbound_id) || Keyword.get(opts, :transcript_id),
        "origin" => inbound_origin(opts),
        "consumption" => if(Keyword.get(opts, :origin), do: "pending", else: nil)
      })
      |> put_inbound_delivery(opts)

    Handbeam.ConversationTranscriptStore.append(conversation_id, entry, opts)
  end

  @spec handle_event(String.t(), {atom(), map()}, keyword()) :: :ok | {:error, term()}
  def handle_event(conversation_id, event, opts \\ [])

  def handle_event(conversation_id, {:run_start, payload}, opts)
      when is_binary(conversation_id) do
    Process.put(assistant_key(conversation_id), nil)
    clear_buffer(conversation_id)
    clear_thinking_buffer(conversation_id)
    Process.put(run_opts_key(conversation_id), opts)
    Process.put(run_payload_key(conversation_id), payload)

    if opts[:origin] && opts[:transcript_id] do
      Handbeam.ConversationTranscriptStore.update(
        conversation_id,
        opts[:transcript_id],
        %{"consumption" => "consumed", "consumed_run_id" => opts[:run_id]},
        opts
      )
    end

    Logger.debug("[TranscriptPersistence] run_start conversation=#{conversation_id}")
    :ok
  end

  def handle_event(conversation_id, {:message_delta, %{chunk: chunk}}, opts)
      when is_binary(conversation_id) and is_binary(chunk) and chunk != "" do
    {thinking_text, clean_chunk, new_buffer} =
      Handbeam.Agent.ThinkingFilter.strip(thinking_buffer(conversation_id), chunk)

    put_thinking_buffer(conversation_id, new_buffer)
    append_thinking(conversation_id, thinking_text)
    append_to_buffer(conversation_id, clean_chunk)
    # The journal syncs the delta before the runtime broadcasts it. The task
    # process is no longer the only owner of an acknowledged visible reply.
    flush!(conversation_id, opts)
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
    flush!(conversation_id, opts)
    :ok = finalize_assistant(conversation_id, "commentary", opts)
    Process.put(assistant_key(conversation_id), nil)

    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)

    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, tool_name),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "tool_use_id" => tool_use_id,
        "tool_name" => tool_name,
        "tool_status" => "running",
        "input" => Handbeam.Log.Redactor.redact(payload_value(payload, :input, %{})),
        "started_at" => now_iso8601()
      })

    {:ok, _saved} = append_or_update(conversation_id, entry, opts)
    :ok
  end

  def handle_event(conversation_id, {:tool_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)
    error = payload_value(payload, :error)
    status = tool_status(payload, error)
    details = payload |> payload_value(:details, %{}) |> Handbeam.JsonSafe.normalize()
    output = payload |> payload_value(:output) |> Handbeam.JsonSafe.normalize()

    patch = %{
      "tool_name" => tool_name,
      "tool_status" => status,
      "tool_duration_ms" => payload_value(payload, :duration_ms),
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

    {:ok, _saved} = append_or_update(conversation_id, entry, opts)
    :ok
  end

  def handle_event(conversation_id, {:candidate_message_injected, %{message_ids: ids}}, opts)
      when is_list(ids) do
    flush!(conversation_id, opts)

    # Text after an injected message answers it, so it must not extend the
    # assistant entry written before the injection.
    if ids != [] do
      :ok = finalize_assistant(conversation_id, "commentary", opts)
      Process.put(assistant_key(conversation_id), nil)
    end

    for id <- ids do
      Handbeam.ConversationTranscriptStore.update(
        conversation_id,
        id,
        %{"consumption" => "consumed", "consumed_run_id" => opts[:run_id]},
        opts
      )
    end

    :ok
  end

  def handle_event(conversation_id, {:stall_check_requested, payload}, opts)
      when is_binary(conversation_id) do
    evidence = payload_value(payload, :evidence) || "检测到没有进展"
    write_notice(conversation_id, "msg-stall-#{opts[:run_id] || "legacy"}", evidence, opts)
    :ok
  end

  def handle_event(conversation_id, {:run_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    record_terminal_usage(conversation_id, payload, opts)
    record_stop_notice(conversation_id, payload, opts)

    run_error = payload_value(payload, :error)

    result =
      cond do
        cancelled_run?(payload) ->
          settle_unfinished(conversation_id, "cancelled", nil, opts)

        not is_nil(run_error) ->
          with :ok <- persist_run_error(conversation_id, run_error, opts) do
            settle_unfinished(conversation_id, "error", run_error, opts)
          end

        true ->
          finalize_assistant(conversation_id, "final", opts)
      end

    with :ok <- result do
      Process.put(assistant_key(conversation_id), nil)
      clear_buffer(conversation_id)
      clear_thinking_buffer(conversation_id)
      Process.delete(run_opts_key(conversation_id))
      Process.delete(run_payload_key(conversation_id))
      :ok
    end
  end

  def handle_event(conversation_id, _event, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)
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
                   %{"tool_status" => "cancelled"},
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

  # Runner persists this before Session broadcasts, so every channel records
  # the same terminal total whether or not a LiveView is connected.
  # `:interrupted` is approval wait, not a finished run; the resumed run_end
  # carries the cumulative usage for the same run_id.
  defp record_stop_notice(conversation_id, payload, opts) do
    status = payload_value(payload, :status)
    error = payload_value(payload, :error)

    text =
      cond do
        status in [:max_turns, "max_turns"] ->
          "已达到 #{payload_value(payload, :turns, 0)} 轮上限，发送消息可继续。"

        status in [:stalled, "stalled"] ->
          "检测到没有进展：#{payload_value(payload, :evidence) || error}。运行已停止。"

        status in [:budget_exceeded, "budget_exceeded"] ->
          "已达到预算上限。运行已停止。"

        status in [:halted, "halted"] ->
          "运行已停止。#{error}"

        is_binary(error) and String.contains?(error, "尚未通过验收") ->
          error

        true ->
          nil
      end

    if is_binary(text) and text != "" do
      write_notice(conversation_id, "msg-run-stop-#{opts[:run_id] || "legacy"}", text, opts)
    else
      :ok
    end
  end

  defp write_notice(conversation_id, id, text, opts) do
    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => id,
        "content_type" => "system_msg",
        "message_type" => "system",
        "role" => "system",
        "direction" => "outbound",
        "content" => text,
        "status" => "final"
      })

    case append_or_update(conversation_id, entry, opts) do
      {:ok, saved} ->
        deliver(saved, opts)
        :ok

      {:error, reason} ->
        Logger.error(
          "[TranscriptPersistence] stop notice failed conversation=#{conversation_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp record_terminal_usage(conversation_id, payload, opts) do
    status = payload_value(payload, :status)
    run_id = opts[:run_id]

    cond do
      status in [:interrupted, "interrupted", nil] ->
        :ok

      not is_binary(run_id) or run_id == "" ->
        :ok

      true ->
        usage = payload_value(payload, :usage)
        usage = if is_map(usage), do: usage, else: %{}

        case Handbeam.ConversationStore.record_run_usage(conversation_id, run_id, usage) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[TranscriptPersistence] run usage not recorded conversation=#{conversation_id} " <>
                "run_id=#{run_id} reason=#{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp settle_unfinished(conversation_id, status, error, opts) do
    with {:ok, entries} <- Handbeam.ConversationTranscriptStore.list(conversation_id, opts) do
      entries
      |> Enum.filter(&(Map.get(&1, "run_id") == opts[:run_id]))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        patch =
          cond do
            tool_entry?(entry) and
                running_tool_status?(Handbeam.TranscriptEntry.tool_status(entry)) ->
              %{
                "tool_status" => status,
                "tool_error" => error
              }

            entry["role"] == "assistant" and entry["status"] == "streaming" ->
              %{"status" => status, "phase" => "final", "error" => error}

            true ->
              nil
          end

        if patch do
          case Handbeam.ConversationTranscriptStore.update(
                 conversation_id,
                 entry["id"],
                 patch,
                 opts
               ) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp persist_run_error(conversation_id, error, opts) do
    # Stable across retries and boot recovery; do not append duplicate errors.
    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => "msg-run-error-#{opts[:run_id] || "legacy"}",
        "content_type" => "system_msg",
        "message_type" => "error",
        "role" => "system",
        "direction" => "outbound",
        "content" => "Run error: #{error}",
        "status" => "final"
      })

    with {:ok, saved} <- append_or_update(conversation_id, entry, opts) do
      deliver(saved, opts)
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

  defp buffered_text(conversation_id) do
    case Process.get(buffer_key(conversation_id)) do
      nil -> ""
      list when is_list(list) -> list |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp clear_buffer(conversation_id) do
    Process.delete(buffer_key(conversation_id))
    Process.delete(last_flush_key(conversation_id))
    :ok
  end

  defp flush!(conversation_id, opts) do
    case buffered_text(conversation_id) do
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
          {:ok, saved} ->
            Process.delete(buffer_key(conversation_id))
            deliver_delta(saved, buffered, opts)

          {:error, reason} ->
            # Do not advance the message boundary or report a successful run.
            # A retry intent now owns this delta; retaining it here would
            # append it twice when a same-process retry drains the durable queue.
            if match?({:queued, _}, reason), do: Process.delete(buffer_key(conversation_id))

            raise "Assistant transcript persistence failed for #{conversation_id}: #{inspect(reason)}"
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
      case Handbeam.ConversationTranscriptStore.update(
             conversation_id,
             assistant_id,
             Map.put(@assistant_completed_patch, "phase", phase),
             opts
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
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

  defp inbound_origin(opts) do
    opts[:origin] ||
      if opts[:source] in [:webhook, :sns, :schedule, :scheduler],
        do: %{"kind" => "automatic", "source" => to_string(opts[:source])}
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp unique_id(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end
end
