defmodule HandbeamProbe.HomeScreen.Async do
  @moduledoc """
  Off-screen IO for `HandbeamProbe.HomeScreen`.

  Mob does not supervise screens, so the screen process must never block on
  disk. Every read or write that is not a single small stat runs here under
  `HandbeamProbe.TaskSupervisor` and reports back as
  `{ref, {kind, generation, result}}`. `run/4` registers the task reference
  in `HandbeamProbe.PendingRequests` (via `HandbeamProbe.HomeScreen.Requests`), so
  `HomeScreen` correlates the reply with `PendingRequests.take/3`: the wire
  generation must match and the scope must not have moved on.

  By default a kind is its own scope and each `run/4` bumps it (latest wins).
  `scope: :composer` binds the task to the composer instead, without bumping.
  `Task.Supervisor.async_nolink/2` also delivers a `:DOWN` message that the
  screen ignores.
  """

  alias HandbeamProbe.HomeScreen.Requests

  @spec run(map(), atom(), (-> term()), keyword()) :: map()
  def run(socket, kind, fun, opts \\ []) when is_atom(kind) and is_function(fun, 0) do
    scope = Keyword.get(opts, :scope, kind)

    {generation, socket} =
      if scope == kind,
        do: Requests.bump(socket, kind),
        else: {Requests.generation(socket, scope), socket}

    task =
      Task.Supervisor.async_nolink(HandbeamProbe.TaskSupervisor, fn ->
        {kind, generation, fun.()}
      end)

    Requests.register(socket, task.ref, kind,
      scope: scope,
      generation: generation,
      ctx: Keyword.get(opts, :ctx, %{})
    )
  end

  @doc "Fire-and-forget IO; the reply is still tagged so tests can wait for it."
  @spec fire(atom(), (-> term())) :: Task.t()
  def fire(tag, fun) when is_atom(tag) and is_function(fun, 0) do
    Task.Supervisor.async_nolink(HandbeamProbe.TaskSupervisor, fn ->
      {tag, nil, fun.()}
    end)
  end
end
