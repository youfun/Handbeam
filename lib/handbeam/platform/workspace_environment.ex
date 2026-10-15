defmodule Handbeam.Platform.WorkspaceEnvironment do
  @moduledoc """
  Captures and caches the interactive login-shell environment for a workspace.

  The macOS desktop helper runs the user's shell in the workspace and returns a
  JSON environment over an output channel isolated from shell startup noise.
  Captured maps are passed to child commands; they never mutate the BEAM's
  process-global environment.
  """

  use GenServer

  alias Handbeam.Platform.CommandEnvironment

  @helper_env "HANDBEAM_DESKTOP_ENV_HELPER"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec environment(Path.t() | nil) :: map()
  def environment(path) when is_binary(path) and path != "" do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:environment, Path.expand(path)}, 10_000)
    else
      %{}
    end
  end

  def environment(_path), do: %{}

  @spec port_env(Path.t() | nil) :: [{String.t(), String.t() | false}]
  def port_env(path), do: path |> environment() |> CommandEnvironment.port_env()

  @spec find_executable(String.t(), Path.t() | nil) :: String.t() | nil
  def find_executable(name, path) do
    CommandEnvironment.find_executable(name, environment(path)) || System.find_executable(name)
  end

  @doc false
  def clear do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :clear), else: :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{environments: %{}}}

  @impl true
  def handle_call({:environment, path}, _from, state) do
    case state.environments do
      %{^path => environment} ->
        {:reply, environment, state}

      _ ->
        environment = capture(path)
        {:reply, environment, put_in(state.environments[path], environment)}
    end
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | environments: %{}}}

  defp capture(path) do
    capture =
      Application.get_env(:handbeam, :workspace_environment_capture, &capture_with_helper/1)

    case capture.(path) do
      {:ok, environment} when is_map(environment) -> CommandEnvironment.sanitize(environment)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp capture_with_helper(path) do
    helper = System.get_env(@helper_env)

    if is_binary(helper) and File.regular?(helper) and File.dir?(path) do
      {output, status} =
        System.cmd(helper, ["--capture-shell-environment", path],
          cd: path,
          stderr_to_stdout: false
        )

      case Handbeam.JSON.decode(output) do
        {:ok, environment} when is_map(environment) -> {:ok, environment}
        _ when status == 0 -> {:error, :invalid_environment}
        _ -> {:error, {:capture_failed, status}}
      end
    else
      {:error, :unavailable}
    end
  end
end
