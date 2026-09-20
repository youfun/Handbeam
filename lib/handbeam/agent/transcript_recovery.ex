defmodule Handbeam.Agent.TranscriptRecovery do
  @moduledoc """
  Seals orphaned durable replies and tools after host restart.

  Visible deltas already live in the transcript journal. Recovery changes only
  unfinished entries; it never replays tools or sends an old reply to a channel.
  An active Runner, including one awaiting approval, remains the lifecycle owner.
  """

  use GenServer

  require Logger

  alias Handbeam.Agent.{Runner, TranscriptPersistence}
  alias Handbeam.ConversationTranscriptStore

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run, do: GenServer.call(__MODULE__, :run, :infinity)
  def recover(id), do: GenServer.call(__MODULE__, {:recover, id}, :infinity)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :recover_on_start, true),
      do: {:ok, nil, {:continue, :recover}},
      else: {:ok, nil}
  end

  @impl true
  def handle_continue(:recover, state) do
    recover_all()
    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, recover_all(), state}

  def handle_call({:recover, id}, _from, state), do: {:reply, recover_orphan(id), state}

  @impl true
  def handle_info({:transcript_retry_persisted, id}, state) do
    case recover_orphan(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[TranscriptRecovery] retry closure #{id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp recover_all do
    items = Path.join(Handbeam.ConversationStore.storage_dir(), "items")

    case File.ls(items) do
      {:ok, ids} ->
        Enum.each(ids, fn id ->
          case recover_orphan(id) do
            :ok -> :ok
            {:error, reason} -> Logger.error("[TranscriptRecovery] #{id}: #{inspect(reason)}")
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("[TranscriptRecovery] cannot scan history: #{inspect(reason)}")
    end

    :ok
  end

  defp recover_orphan(conversation_id) do
    case Runner.status(conversation_id) do
      {:error, :not_found} ->
        with {:ok, entries} <- ConversationTranscriptStore.list(conversation_id) do
          recover_runs(conversation_id, entries)
        end

      _ ->
        :ok
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp recover_runs(conversation_id, entries) do
    entries
    |> Enum.filter(fn entry ->
      (entry["role"] == "assistant" and entry["status"] == "streaming") or
        (entry["content_type"] == "tool" and
           Handbeam.TranscriptEntry.tool_status(entry) in [:running, "running"])
    end)
    |> Enum.map(& &1["run_id"])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn run_id, :ok ->
      result =
        TranscriptPersistence.handle_event(
          conversation_id,
          {:run_end, %{status: "error", error: "Host stopped before the run completed"}},
          run_id: run_id,
          source: :recovery
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
