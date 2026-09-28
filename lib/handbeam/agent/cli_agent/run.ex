defmodule Handbeam.Agent.CliAgent.Run do
  @moduledoc """
  One user turn whose loop owner is a CLI agent.

  Handbeam opens the session, sends the message, and projects normalized
  events into the existing transcript path. It does not call Provider, attach
  Handbeam tool definitions, or pass CLI tool events to
  `Handbeam.Agent.Tool.Executor`.

  This module is unused unless a caller selects a backend id. The default
  chat path remains `Handbeam.Agent.Turn`.
  """

  alias Handbeam.Agent.CliAgent.{Event, Registry}
  alias Handbeam.Agent.TranscriptPersistence
  alias Handbeam.Host
  alias Handbeam.PubSub.Session, as: PubSubSession

  @doc """
  Run one CLI-owned turn.

  Options:

    * `:backend` — registry id, such as `"droid"`
    * `:cwd` — workspace directory
    * `:model` — the CLI's own model id
    * `:reasoning_effort` — a level that CLI accepts
    * `:session_id` — resume a backend session
    * `:auto` — `:low`, `:medium`, or `:high`; omitted means the backend default
    * `:conversation_id` — when set, events are persisted and broadcast
    * `:decision` — explicit permission or ask-user answer; never invented here
  """
  @spec turn(String.t(), keyword()) ::
          {:ok, String.t(), map()}
          | {:awaiting, :permission | :ask_user, map()}
          | {:error, term()}
  def turn(text, opts) when is_binary(text) and is_list(opts) do
    backend = Keyword.get(opts, :backend)

    with :ok <- host_available(),
         {:ok, module} <- Registry.fetch(backend),
         true <- module.available?() || {:error, :not_available},
         {:ok, session} <- module.start_session(start_opts(opts)),
         session <- maybe_decision(module, session, opts) do
      try do
        conversation_id = Keyword.get(opts, :conversation_id)
        on_event = fn event -> project(conversation_id, event, opts) end

        case module.send_message(session, text, on_event) do
          {:ok, session, events} ->
            finish_turn(session, events)

          {:error, reason} ->
            project(conversation_id, {:error, reason_text(reason)}, opts)
            {:error, reason}
        end
      after
        module.stop_session(session)
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_available}
    end
  end

  @doc """
  Project one normalized event into the transcript and session bus.

  Tool events are recorded as child activity. They are not executed.
  A permission or ask-user request that arrives here has already stopped the
  turn unless the caller answered it; this function does not approve it.
  """
  @spec project(String.t() | nil, Event.t(), keyword()) :: :ok
  def project(nil, event, _opts) when is_tuple(event) do
    if Event.normalized?(event), do: :ok, else: :ok
  end

  def project(conversation_id, event, opts) when is_binary(conversation_id) do
    if Event.normalized?(event) do
      persist(conversation_id, event, opts)
      broadcast(conversation_id, event, opts)
    end

    :ok
  end

  defp finish_turn(session, events) do
    meta = %{session_id: session.session_id, backend: session.backend}

    case awaiting(events) do
      nil -> {:ok, final_text(events), meta}
      request -> {:awaiting, request.kind, Map.merge(meta, request)}
    end
  end

  defp awaiting(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:permission_request, request} ->
        if is_nil(request[:selected]),
          do: %{kind: :permission, request: request, options: request[:options] || []}

      {:ask_user, request} ->
        if is_nil(request[:answers]), do: %{kind: :ask_user, request: request, options: []}

      _ ->
        nil
    end)
  end

  defp host_available do
    if Host.shell?(), do: :ok, else: {:error, :not_available}
  end

  defp start_opts(opts) do
    Keyword.take(opts, [
      :cwd,
      :model,
      :reasoning_effort,
      :session_id,
      :auto,
      :executable,
      :timeout
    ])
  end

  defp maybe_decision(module, session, opts) do
    case Keyword.get(opts, :decision) do
      nil ->
        session

      decision ->
        session =
          if function_exported?(module, :put_decision, 2),
            do: module.put_decision(session, decision),
            else: session

        private = Map.put(session.private || %{}, :decision, decision)
        %{session | private: private}
    end
  end

  defp persist(conversation_id, {:text_delta, text}, opts) do
    TranscriptPersistence.handle_event(conversation_id, {:message_delta, %{chunk: text}}, opts)
  end

  defp persist(conversation_id, {:tool_start, tool}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start,
       %{
         tool: tool.name,
         tool_use_id: tool.id,
         input: Map.get(tool, :input, %{}),
         projected: true
       }},
      opts
    )
  end

  defp persist(conversation_id, {:tool_end, tool}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end,
       %{
         tool_use_id: tool.id,
         output: Map.get(tool, :output, ""),
         error: if(tool[:is_error], do: "cli tool error"),
         projected: true
       }},
      opts
    )
  end

  defp persist(conversation_id, {:usage, usage}, opts) do
    TranscriptPersistence.handle_event(conversation_id, {:delegation_usage, usage}, opts)
  end

  defp persist(conversation_id, {:turn_end, done}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: done[:stop_reason] || :end_turn, session_id: done[:session_id]}},
      opts
    )
  end

  defp persist(conversation_id, {:error, reason}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: :error, error: reason_text(reason)}},
      opts
    )
  end

  defp persist(_conversation_id, _event, _opts), do: :ok

  defp broadcast(conversation_id, {tag, payload}, opts) do
    PubSubSession.broadcast_event(conversation_id, tag, broadcast_payload(tag, payload, opts))
  end

  defp broadcast_payload(:text_delta, text, opts), do: stamp(%{chunk: text}, opts)
  defp broadcast_payload(_tag, payload, opts) when is_map(payload), do: stamp(payload, opts)
  defp broadcast_payload(_tag, payload, opts), do: stamp(%{reason: payload}, opts)

  defp stamp(payload, opts) do
    payload
    |> Map.put(:loop_owner, :cli_agent)
    |> Map.put(:run_id, Keyword.get(opts, :run_id))
    |> Map.put(:projected, true)
  end

  defp final_text(events) do
    events
    |> Enum.filter(&match?({:text_delta, _}, &1))
    |> Enum.map_join("", fn {:text_delta, text} -> text end)
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
