defmodule Handbeam.Threads do
  @moduledoc """
  Authorized projections of durable conversations. No runtime is owned here.

  Cursors expire after one hour and bind the caller, query and complete projected
  snapshot. Any append, edit or deletion invalidates pagination: restart explicitly.
  Character offsets count Unicode codepoints, including within a single message.
  Each page has at most 16,000 codepoints and 50 message fragments.
  """
  alias Handbeam.{ConversationStore, ConversationTranscriptStore}

  def identity(%{conversation_id: id, workspace_id: workspace}) when is_binary(workspace) do
    with {:ok, meta} <- ConversationStore.get_metadata(id),
         true <- meta["workspace_id"] == workspace and visible?(meta) and not free_chat?(meta) do
      {:ok, meta}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def identity(_), do: {:error, :unauthorized}

  def authorize(context, id) do
    with {:ok, source} <- identity(context),
         {:ok, target} <- ConversationStore.get_metadata(id),
         true <-
           target["workspace_id"] == source["workspace_id"] and visible?(target) and
             not free_chat?(target) do
      {:ok, target}
    else
      _ -> {:error, :not_accessible}
    end
  end

  def visible?(meta), do: meta["visibility"] not in ["internal", "task"]

  defp free_chat?(meta), do: meta["scope"] == "free"

  def find(input, context) do
    with {:ok, source} <- identity(context),
         :ok <- validate(input, ~w(query updated_after include_archived limit cursor)),
         true <- is_boolean(Map.get(input, "include_archived", false)),
         {:ok, query} <- text(input, "query", "", 200),
         {:ok, after_time} <- text(input, "updated_after", "", 40),
         {:ok, after_time} <- timestamp(after_time),
         {:ok, limit} <- integer(input, "limit", 10, 1, 20) do
      entries =
        ConversationStore.list_metadata(source["workspace_id"])
        |> Enum.filter(fn m ->
          visible?(m) and (input["include_archived"] == true or is_nil(m["archived_at"])) and
            String.contains?(String.downcase(m["title"] || ""), String.downcase(query)) and
            updated_since?(m["updated_at"], after_time)
        end)
        |> Enum.sort_by(&{&1["updated_at"] || "", &1["id"]}, :desc)
        |> Enum.map(fn m ->
          Map.take(m, ~w(id updated_at created_at archived_at))
          |> Map.put("title", String.slice(m["title"] || "", 0, 200))
          |> Map.put("summary", String.slice(m["title"] || "", 0, 200))
          |> Map.put("summary_source", "title")
          |> Map.put("summary_truncated", String.length(m["title"] || "") > 200)
        end)

      binding = binding("find", context, input, entries)

      with {:ok, offset} <- position(input["cursor"], binding) do
        next = offset + limit

        {:ok,
         %{
           threads: Enum.slice(entries, offset, limit),
           next_cursor: cursor(next < length(entries), binding, next)
         }}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def read(input, context) do
    with :ok <- validate(input, ~w(thread start_message end_message max_chars cursor)),
         {:ok, _} <- authorize(context, input["thread"]),
         {:ok, first} <- integer(input, "start_message", 0, 0, 1_000_000),
         {:ok, last} <- integer(input, "end_message", 1_000_000, first, 1_000_000),
         {:ok, max} <- integer(input, "max_chars", 8000, 1, 16000),
         {:ok, entries} <- ConversationTranscriptStore.list(input["thread"]) do
      messages = entries |> Enum.map(&project_message/1) |> Enum.slice(first..last)
      binding = binding("read", context, input, messages)

      with {:ok, offset} <- position(input["cursor"], binding) do
        {parts, remaining, consumed} = slice_messages(messages, offset, max)

        {:ok,
         %{
           messages: parts,
           truncated: remaining,
           next_cursor: cursor(remaining, binding, offset + consumed)
         }}
      end
    end
  end

  def status(input, context) do
    with :ok <- validate(input, ["thread"]),
         {:ok, meta} <- authorize(context, input["thread"]) do
      runtime =
        case Handbeam.Agent.Coordinator.status(meta["id"]) do
          {:ok, value} -> value
          _ -> %{}
        end

      state =
        cond do
          runtime[:status] in [
            :awaiting_approval,
            "awaiting_approval",
            :interrupted,
            "interrupted"
          ] and runtime[:running?] ->
            "awaiting_approval"

          runtime[:running?] ->
            "running"

          true ->
            "idle"
        end

      {:ok,
       %{
         id: meta["id"],
         state: state,
         current_run: runtime[:run_id],
         last_activity: meta["updated_at"],
         last_result: meta["last_run_result"],
         note: "idle means no active run, not successful completion"
       }}
    end
  end

  def project_message(entry) do
    content = entry["content"]

    %{
      "id" => entry["id"],
      "role" => entry["role"],
      "content" => if(is_binary(content), do: Handbeam.Log.Redactor.redact(content), else: ""),
      "created_at" => entry["created_at"],
      "handoff_id" => entry["handoff_id"] || get_in(entry, ["origin", "handoff_id"]),
      "consumption" => entry["consumption"]
    }
  end

  def validate(input, keys) when is_map(input) do
    if Enum.all?(Map.keys(input), &(&1 in keys)), do: :ok, else: {:error, :invalid_input}
  end

  def validate(_, _), do: {:error, :invalid_input}

  def text(input, key, default, max) do
    value = Map.get(input, key, default)

    if is_binary(value) and byte_size(value) <= max * 4 and String.valid?(value) and
         String.length(value) <= max, do: {:ok, value}, else: {:error, :invalid_input}
  end

  def integer(input, key, default, min, max) do
    value = Map.get(input, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, :invalid_input}
  end

  defp binding(kind, context, input, snapshot) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {kind, context.conversation_id, context.workspace_id, Map.delete(input, "cursor"),
         snapshot}
      )
    )
    |> Base.url_encode64(padding: false)
  end

  defp timestamp(""), do: {:ok, nil}

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> {:error, :invalid_input}
    end
  end

  defp updated_since?(_, nil), do: true

  defp updated_since?(value, threshold) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.compare(datetime, threshold) != :lt
      _ -> false
    end
  end

  defp updated_since?(_, _), do: false

  defp position(nil, _binding), do: {:ok, 0}

  defp position(token, binding) when is_binary(token) and byte_size(token) <= 2048 do
    case Phoenix.Token.verify(HandbeamWeb.Endpoint, "thread-page", token, max_age: 3600) do
      {:ok, {^binding, offset}} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _ -> {:error, :stale_or_invalid_cursor}
    end
  end

  defp position(_, _), do: {:error, :stale_or_invalid_cursor}
  defp cursor(false, _, _), do: nil

  defp cursor(true, binding, offset),
    do: Phoenix.Token.sign(HandbeamWeb.Endpoint, "thread-page", {binding, offset})

  defp slice_messages(messages, offset, budget) do
    {parts, _, _left, consumed, remaining} =
      Enum.reduce(messages, {[], offset, budget, 0, false}, fn m,
                                                               {parts, skip, left, used, more} ->
        codepoints = String.to_charlist(m["content"])
        size = max(length(codepoints), 1)

        cond do
          skip >= size ->
            {parts, skip - size, left, used, more}

          left == 0 or length(parts) >= 50 ->
            {parts, skip, left, used, true}

          true ->
            count = min(size - skip, left)

            part =
              m
              |> Map.put("content", codepoints |> Enum.slice(skip, count) |> List.to_string())
              |> Map.put("offset", skip)
              |> Map.put("continued", skip + count < size)

            {[part | parts], 0, left - count, used + count, more or skip + count < size}
        end
      end)

    {Enum.reverse(parts), remaining, consumed}
  end
end
