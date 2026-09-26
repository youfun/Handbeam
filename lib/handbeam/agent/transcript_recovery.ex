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

  @startup_delay_ms 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run, do: GenServer.call(__MODULE__, :run, :infinity)
  def recover(id), do: GenServer.call(__MODULE__, {:recover, id}, :infinity)

  def mark(id) when is_binary(id) do
    with {:ok, path} <- marker_path(id),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "") do
      :ok
    else
      _ -> :ok
    end
  end

  def clear(id) when is_binary(id) do
    with {:ok, path} <- marker_path(id) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> :ok
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :recover_on_start, true) do
      Process.send_after(self(), :recover, @startup_delay_ms)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:recover, state) do
    recover_marked()
    {:noreply, state}
  end

  def handle_info({:transcript_retry_persisted, id}, state) do
    case recover_orphan(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[TranscriptRecovery] retry closure #{id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, recover_all(), state}

  def handle_call({:recover, id}, _from, state), do: {:reply, recover_orphan(id), state}

  defp recover_marked do
    case File.ls(marker_dir()) do
      {:ok, ids} ->
        Enum.each(ids, fn id ->
          case recover_orphan(id) do
            :ok -> clear(id)
            {:error, reason} -> Logger.error("[TranscriptRecovery] #{id}: #{inspect(reason)}")
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("[TranscriptRecovery] cannot scan candidates: #{inspect(reason)}")
    end

    :ok
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

  defp marker_path(id) do
    if byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) do
      {:ok, Path.join(marker_dir(), id)}
    else
      {:error, :invalid_conversation_id}
    end
  end

  defp marker_dir do
    Handbeam.Home.expand("~/.handbeam/runtime/transcript-recovery")
  end
end
