defmodule Handbeam.Browser.Supervisor do
  @moduledoc """
  Dynamic supervisor for conversation-scoped browser sessions.

  Lives in the application tree, not under extension workers or a
  single agent run. Extensions must not start their own browser Ports.
  """

  use DynamicSupervisor

  alias Handbeam.Browser.{Registry, Session}

  @default_slot "default"

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(conversation_id, opts \\ []) when is_binary(conversation_id) do
    case Registry.lookup(conversation_id, @default_slot) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        spec = %{
          id: {conversation_id, @default_slot},
          start: {Session, :start_link, [Keyword.put(opts, :conversation_id, conversation_id)]},
          restart: :temporary
        }

        DynamicSupervisor.start_child(__MODULE__, spec)
    end
  end

  @spec stop_session(String.t()) :: :ok
  def stop_session(conversation_id) when is_binary(conversation_id) do
    case Registry.lookup(conversation_id, @default_slot) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))
end
