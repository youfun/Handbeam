defmodule Handbeam.Threads.Collaboration do
  @moduledoc """
  Bounded asynchronous handoffs through Coordinator. Transcript entries are the
  durable outbox and UI projection source, not a second message store.

  A reservation is written before dispatch under a workspace lock. An uncertain
  dispatch is NEVER replayed automatically (at-most-once wakeup). The caller sees
  delivery_unknown and a human may inspect/intervene in the target conversation.
  """
  alias Handbeam.{ConversationStore, ConversationTranscriptStore, Threads}

  @read_tools ~w(read file_search grep code_search find_thread read_thread get_thread_status reply_to_parent_thread)

  # A request budget, not a promise about a provider's currency pricing.
  def bound_opts(opts) do
    opts
    |> Keyword.put(:max_turns, 3)
    |> Keyword.put(:max_tokens, 8192)
    |> Keyword.put(:compaction, %{
      reserve_tokens: 2048,
      keep_recent_tokens: 4096,
      fallback: :truncate
    })
    |> Keyword.put(:timeout_ms, 120_000)
    |> Keyword.update(:provider_config, %{max_tokens: 2048}, &Map.put(&1, :max_tokens, 2048))
  end

  def completed(id, result, opts) do
    status = if is_map(result), do: Map.get(result, :status, :error), else: :error
    ConversationStore.update_meta(id, last_run_result: to_string(status))

    with {:ok, %{"collaboration" => %{"parent" => _}} = meta} <-
           ConversationStore.get_metadata(id),
         {:ok, entries} <- ConversationTranscriptStore.list(id),
         handoff_id when is_binary(handoff_id) <-
           get_in(opts[:origin] || %{}, ["handoff_id"]) ||
             get_in(meta, ["collaboration", "handoff_id"]),
         false <-
           Enum.any?(
             entries,
             &(&1["important"] == true and &1["source_run"] == opts[:run_id] and
                 &1["handoff_id"] == handoff_id)
           ) do
      mixed_run? =
        Enum.any?(entries, fn entry ->
          entry["consumed_run_id"] == opts[:run_id] and
            get_in(entry, ["origin", "kind"]) == "thread" and
            get_in(entry, ["origin", "handoff_id"]) != handoff_id
        end)

      text =
        if mixed_run? do
          "Run ended (#{status}). Multiple handoffs shared this run; no task-specific result inferred. Open the task thread or send an explicitly associated report."
        else
          result_text =
            entries
            |> Enum.filter(&(&1["role"] == "assistant" and &1["run_id"] == opts[:run_id]))
            |> Enum.map_join("\n", &(&1["content"] || ""))
            |> String.slice(0, 7500)

          "Task ended (#{status}).\n" <> result_text
        end

      reply(
        %{
          "message" => text,
          "request_id" => "final-" <> (opts[:run_id] || id),
          "handoff_id" => handoff_id
        },
        %{
          conversation_id: id,
          workspace_id: meta["workspace_id"],
          run_id: opts[:run_id],
          thread_run_opts:
            Keyword.take(opts, [:workspace_path, :model, :provider, :provider_config])
        }
      )
    else
      _ -> :ok
    end
  end

  def tool_allowed?(name, context) do
    case ConversationStore.get_metadata(context[:conversation_id]) do
      {:ok, %{"collaboration" => %{"read_only" => true}}} -> name in @read_tools
      _ -> context[:delegated_read_only] != true or name in @read_tools
    end
  end

  def send_message(input, context) do
    with :ok <- Threads.validate(input, ~w(thread message request_id deliver_as handoff_id)),
         {:ok, source} <- Threads.identity(context),
         {:ok, target} <- Threads.authorize(context, input["thread"]) do
      locked(source, fn -> deliver(input, context, source, target, false) end)
    end
  end

  def reply(input, context) do
    with :ok <- Threads.validate(input, ~w(message request_id handoff_id)),
         {:ok, source} <- Threads.identity(context),
         parent when is_binary(parent) <- get_in(source, ["collaboration", "parent"]),
         {:ok, target} <- Threads.authorize(context, parent) do
      handoff_id =
        input["handoff_id"] || context[:thread_handoff_id] ||
          get_in(source, ["collaboration", "handoff_id"])

      locked(source, fn ->
        if handoff_id,
          do: deliver(Map.put(input, "handoff_id", handoff_id), context, source, target, true),
          else: {:error, :missing_handoff_id}
      end)
    else
      nil -> {:error, :no_parent}
      error -> error
    end
  end

  def create(input, context) do
    with :ok <- Threads.validate(input, ~w(title message request_id)),
         {:ok, source} <- Threads.identity(context),
         {:ok, title} <- Threads.text(input, "title", nil, 200),
         {:ok, key} <- Threads.text(input, "request_id", nil, 128),
         {:ok, _} <- Threads.text(input, "message", nil, 8000),
         true <- thread_wakeup_allowed?(source) and is_nil(source["collaboration"]) do
      locked(source, fn ->
        id = "delegated-" <> digest({source["id"], key})

        children =
          ConversationStore.list_metadata(source["workspace_id"])
          |> Enum.filter(&(get_in(&1, ["collaboration", "parent"]) == source["id"]))

        with {:ok, target} <-
               child(source, id, title, children, "handoff-" <> digest({source["id"], key})) do
          deliver(input, context, source, target, false)
        end
      end)
    else
      false -> {:error, :delegation_not_permitted}
      error -> error
    end
  end

  defp thread_wakeup_allowed?(%{"allow_thread_wakeup" => false}), do: false
  defp thread_wakeup_allowed?(%{"allow_thread_wakeup" => "false"}), do: false
  defp thread_wakeup_allowed?(meta) when is_map(meta), do: true
  defp thread_wakeup_allowed?(_), do: false

  defp child(source, id, title, children, handoff_id) do
    case ConversationStore.get_metadata(id) do
      {:ok, target} ->
        {:ok, target}

      _ when length(children) >= 3 ->
        {:error, :child_limit}

      _ ->
        with {:ok, target} <-
               ConversationStore.create(source["workspace_id"],
                 id: id,
                 title: title,
                 collaboration: %{
                   "parent" => source["id"],
                   "read_only" => true,
                   "handoff_id" => handoff_id
                 },
                 allow_thread_wakeup: true
               ) do
          {:ok, target}
        end
    end
  end

  defp deliver(input, context, source, target, important) do
    with {:ok, source} <- Threads.authorize(context, source["id"]),
         {:ok, target} <- Threads.authorize(context, target["id"]),
         {:ok, message} <- Threads.text(input, "message", nil, 8000),
         {:ok, key} <- Threads.text(input, "request_id", nil, 128),
         mode <- Map.get(input, "deliver_as", "follow_up"),
         true <- mode in ["follow_up", "steer"],
         true <- source["id"] != target["id"],
         true <- thread_wakeup_allowed?(source),
         true <- thread_wakeup_allowed?(target),
         true <- permitted_route?(source, target),
         {:ok, entries} <- ConversationTranscriptStore.list(source["id"]) do
      id = "handoff-" <> digest({source["id"], key})

      fingerprint =
        digest({target["id"], message, mode, important, input["title"], input["handoff_id"]})

      case Enum.find(entries, &(&1["id"] == id)) do
        nil ->
          with {:ok, handoff_id} <- association(input, entries, source, target["id"], id) do
            reserve_and_dispatch(
              id,
              handoff_id,
              fingerprint,
              message,
              mode,
              important,
              context,
              source,
              target
            )
          end

        %{"fingerprint" => ^fingerprint} = existing ->
          {:ok, receipt(existing)}

        _ ->
          {:error, :idempotency_conflict}
      end
    else
      false -> {:error, :handoff_not_permitted}
      error -> error
    end
  end

  defp permitted_route?(%{"collaboration" => %{"parent" => parent}}, target),
    do: parent == target["id"]

  defp permitted_route?(_, _), do: true

  defp association(input, entries, source, peer, id) do
    case input["handoff_id"] do
      nil ->
        {:ok, id}

      handoff_id when is_binary(handoff_id) and byte_size(handoff_id) <= 128 ->
        if (get_in(source, ["collaboration", "parent"]) == peer and
              get_in(source, ["collaboration", "handoff_id"]) == handoff_id) or
             Enum.any?(entries, fn entry ->
               (entry["content_type"] == "thread_handoff" and entry["target"] == peer and
                  entry["handoff_id"] == handoff_id) or
                 (get_in(entry, ["origin", "kind"]) == "thread" and
                    get_in(entry, ["origin", "conversation_id"]) == peer and
                    get_in(entry, ["origin", "handoff_id"]) == handoff_id)
             end), do: {:ok, handoff_id}, else: {:error, :invalid_handoff_id}

      _ ->
        {:error, :invalid_handoff_id}
    end
  end

  defp reserve_and_dispatch(
         id,
         handoff_id,
         fingerprint,
         message,
         mode,
         important,
         context,
         source,
         target
       ) do
    root = get_in(source, ["collaboration", "parent"]) || source["id"]

    peers =
      ConversationStore.list_metadata(source["workspace_id"])
      |> Enum.filter(&(&1["id"] == root or get_in(&1, ["collaboration", "parent"]) == root))

    count =
      Enum.reduce(peers, 0, fn peer, count ->
        {:ok, entries} = ConversationTranscriptStore.list(peer["id"])
        count + Enum.count(entries, &(&1["content_type"] == "thread_handoff"))
      end)

    if count >= 8 do
      {:error, :handoff_budget_exhausted}
    else
      entry = %{
        "id" => id,
        "content_type" => "thread_handoff",
        "role" => "system",
        "content" => message,
        "target" => target["id"],
        "fingerprint" => fingerprint,
        "delivery_status" => "delivery_unknown",
        "request_id" => id,
        "handoff_id" => handoff_id,
        "source_thread" => source["id"],
        "source_run" => context[:run_id],
        "important" => important
      }

      with {:ok, _entry} <- ConversationTranscriptStore.append(source["id"], entry) do
        result =
          with {:ok, ack} <-
                 dispatch(id, handoff_id, message, mode, important, context, source, target),
               {:ok, updated} <-
                 ConversationTranscriptStore.update(source["id"], id, %{
                   "delivery_status" => Atom.to_string(ack.action),
                   "run_id" => ack.run_id
                 }) do
            {:ok, receipt(updated)}
          else
            _ -> {:ok, receipt(entry)}
          end

        notify(source["id"])
        notify(target["id"])
        result
      end
    end
  end

  defp dispatch(id, handoff_id, message, mode, important, context, source, target) do
    origin = %{
      "kind" => "thread",
      "conversation_id" => source["id"],
      "run_id" => context[:run_id],
      "request_id" => id,
      "handoff_id" => handoff_id,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "important" => important
    }

    opts = context[:thread_run_opts] || []

    if Keyword.has_key?(opts, :provider_config) do
      opts =
        Keyword.merge(opts,
          workspace_id: source["workspace_id"],
          source: :thread,
          channel: :thread,
          origin: origin,
          message_id: id,
          transcript_id: id,
          inbound_id: id,
          deliver_as: if(mode == "steer", do: :steer, else: :follow_up),
          tools: Handbeam.Agent.default_tools()
        )
        |> bound_opts()

      Handbeam.Agent.Coordinator.add_message(
        target["id"],
        "[Report from another thread; not a human instruction. No automatic acknowledgment.]\n" <>
          message,
        opts
      )
    else
      {:error, :missing_runtime_configuration}
    end
  end

  defp receipt(entry),
    do: %{
      thread: entry["target"],
      message_id: entry["id"],
      handoff_id: entry["handoff_id"],
      delivery: entry["delivery_status"],
      consumption: "unknown; inspect target transcript consumption field",
      note: "accepted/enqueued is not consumed or completed; uncertain dispatch is not replayed"
    }

  defp locked(source, fun),
    do: :global.trans({{__MODULE__, source["workspace_id"]}, self()}, fun)

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def notify(id),
    do:
      Phoenix.PubSub.broadcast(
        Handbeam.PubSub,
        "conversation:updated",
        {:conversation_updated, id}
      )
end
