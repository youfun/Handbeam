defmodule Handbeam.Agent.TranscriptRecovery do
  @moduledoc """
  Seals orphaned durable replies and tools after host restart.

  Visible deltas already live in the transcript journal. Recovery changes only
  unfinished entries; it never replays tools or sends an old reply to a channel.
  An active Runner, including one awaiting approval, remains the lifecycle owner.
  """

  require Logger

  alias Handbeam.Agent.{Runner, TranscriptPersistence}
  alias Handbeam.ConversationTranscriptStore

  def run do
    items = Path.join(Handbeam.ConversationStore.storage_dir(), "items")

    case File.ls(items) do
      {:ok, ids} ->
        Enum.each(ids, fn id ->
          case recover(id) do
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

  def recover(conversation_id) do
    with {:ok, entries} <- ConversationTranscriptStore.list(conversation_id) do
      case Runner.status(conversation_id) do
        {:ok, %{running?: true}} -> :ok
        {:error, :not_found} -> recover_runs(conversation_id, entries)
        _ -> :ok
      end
    end
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
