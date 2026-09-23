defmodule Handbeam.SessionStore do
  @moduledoc """
  Behaviour for runtime session snapshot persistence.

  Stores only recoverable runtime data. It must not store process ids, task refs,
  queue pids, ports, or provider connections.
  """

  @callback save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback load(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback list_active(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  @callback update(String.t(), map(), keyword()) :: :ok | {:error, term()}
end
