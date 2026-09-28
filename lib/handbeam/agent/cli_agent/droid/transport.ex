defmodule Handbeam.Agent.CliAgent.Droid.Transport do
  @moduledoc """
  Port transport for one `droid exec` stream JSON-RPC process.

  The executable path is resolved here. Tests pass `:executable` so the real
  Factory CLI is never required. `FACTORY_API_KEY`, when present, is inherited
  from the host environment and is not copied into arguments or logs.
  """

  alias Handbeam.Agent.CliAgent.Droid.Codec
  alias Handbeam.Platform.ProcessManager

  @executable "droid"

  @doc "Open the long-lived exec process. Does not write a request."
  @spec open(keyword()) ::
          {:ok, port(), pos_integer() | nil} | {:error, :not_available | String.t()}
  def open(opts) do
    with {:ok, executable} <- resolve(opts) do
      spawn_port(executable, Codec.argv(opts))
    end
  end

  @doc "Write one JSON-RPC line. A dead port is an error, not a retry."
  @spec write(port(), iodata()) :: :ok | {:error, :port_closed}
  def write(port, line) do
    if Port.info(port) == nil do
      {:error, :port_closed}
    else
      Port.command(port, line)
      :ok
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @doc "Close the port and its process tree."
  @spec close(port() | nil, pos_integer() | nil) :: :ok
  def close(nil, _os_pid), do: :ok

  def close(port, os_pid) do
    ProcessManager.kill_process_tree(os_pid)
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp resolve(opts) do
    case Keyword.get(opts, :executable) do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_available}

      _ ->
        case System.find_executable(@executable) do
          nil -> {:error, :not_available}
          path -> {:ok, path}
        end
    end
  end

  defp spawn_port(executable, argv) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(argv, &String.to_charlist/1)},
        {:line, 65_536}
      ])

    {:ok, port, os_pid(port)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
