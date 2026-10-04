defmodule Handbeam.Agent.CliAgent.Grok.Transport do
  @moduledoc """
  Port transport for one `grok agent stdio` process.

  Tests pass `:executable`. The real CLI is not required to compile or test.
  Host login is inherited by the child process and is not copied into arguments.
  """

  alias Handbeam.Agent.CliAgent.Grok.Codec
  alias Handbeam.Platform.ProcessManager

  @executable "grok"

  @spec open(keyword()) ::
          {:ok, port(), pos_integer() | nil} | {:error, :not_available | String.t()}
  def open(opts) do
    with {:ok, executable} <- resolve(opts) do
      spawn_port(executable, Codec.argv(opts), Keyword.get(opts, :cwd))
    end
  end

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

  @spec close(port() | nil, pos_integer() | nil) :: :ok
  def close(nil, _os_pid), do: :ok

  def close(port, os_pid) do
    ProcessManager.kill_process_tree(os_pid)
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  @spec models(keyword()) :: {:ok, String.t()} | {:error, :not_available | String.t()}
  def models(opts) do
    with {:ok, executable} <- resolve(opts) do
      cwd = Keyword.get(opts, :cwd) || File.cwd!()

      case System.cmd(executable, ["models"], cd: cwd, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, status} ->
          {:error, "grok models exited #{status}: #{String.slice(output, 0, 200)}"}
      end
    end
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

  defp spawn_port(executable, argv, cwd) do
    options = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:args, Enum.map(argv, &String.to_charlist/1)},
      {:line, 65_536}
    ]

    options = if is_binary(cwd) and cwd != "", do: [{:cd, cwd} | options], else: options
    port = Port.open({:spawn_executable, executable}, options)
    {:ok, port, os_pid(port)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end
end
