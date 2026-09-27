defmodule Handbeam.Platform.ProcessRunner.Invocation do
  @moduledoc """
  Supervised owner of one OS invocation.

  The business owner is monitored before `Port.open`. This process holds the
  port and cleans up the recorded invocation on cancel, owner death, or its
  own terminate. A supervisor must start it as temporary so a crash does not
  re-run the command. Callers cancel with a message; they must not kill this
  process to clean up.
  """

  use GenServer

  alias Handbeam.Platform.ProcessRunner

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def run(opts) do
    Handbeam.Platform.ProcessRunner.InvocationSupervisor.start_invocation(opts)
  end

  @impl true
  def init(opts) do
    business = Keyword.fetch!(opts, :business_owner)
    Process.monitor(business)
    if is_pid(opts[:reply_to]), do: Process.monitor(opts[:reply_to])

    {:ok, %{opts: opts, business: business, port: nil, os_pid: nil, invocation: nil, chunks: []},
     {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    if hold = state.opts[:hold_before_open] do
      send(hold, {:held_before_open, self()})

      receive do
        :release_open -> :ok
      end
    end

    caller = state.opts[:reply_to]

    if not Process.alive?(state.business) or (is_pid(caller) and not Process.alive?(caller)) do
      reply(state, {:error, :cancelled})
      {:stop, :normal, state}
    else
      open_and_track(state)
    end
  end

  defp open_and_track(state) do
    case open_port(state.opts) do
      {:ok, port, os_pid, invocation} ->
        caller = state.opts[:reply_to]

        if is_pid(caller) do
          send(caller, {:invocation_opened, self(), os_pid})
        end

        {:noreply, %{state | port: port, os_pid: os_pid, invocation: invocation}}

      {:error, reason} ->
        reply(state, {:error, reason})
        {:stop, {:open_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    caller = state.opts[:reply_to]

    if pid == state.business or pid == caller do
      # This process owns the port. A business-owner or caller exit sends DOWN;
      # callers must not kill this process. Cleanup runs here, including when
      # the DOWN arrives while Port.open is still in progress: the port is
      # closed and the recorded OS pid is killed. This does not cover :kill of
      # this process or a VM crash.
      cleanup(state)
      reply(state, {:error, :cancelled})
      {:stop, :normal, %{state | port: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    output = IO.iodata_to_binary(Enum.reverse(state.chunks))

    result =
      if code == 0 do
        {:ok, output, %{exit_code: 0, timed_out: false}}
      else
        content = if output == "", do: "", else: output <> "\n\n"
        {:ok, "#{content}Command exited with code #{code}", %{exit_code: code, timed_out: false}}
      end

    reply(state, result)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    if is_pid(state.opts[:reply_to]) do
      send(state.opts[:reply_to], {:invocation_data, self(), data})
    end

    {:noreply, %{state | chunks: [data | state.chunks]}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    cleanup(state)
    reply(state, {:error, "cancelled"})
    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp open_port(opts) do
    ProcessRunner.open_tracked(opts)
  end

  defp cleanup(%{os_pid: pid, invocation: invocation}) when is_integer(pid) do
    ProcessRunner.cleanup_owned(pid, invocation || %{})
  end

  defp cleanup(_state), do: :ok

  defp reply(state, result) do
    if is_pid(state.opts[:reply_to]),
      do: send(state.opts[:reply_to], {:invocation_result, self(), result})
  end
end
