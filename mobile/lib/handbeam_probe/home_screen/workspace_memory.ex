defmodule HandbeamProbe.HomeScreen.WorkspaceMemory do
  @moduledoc "HomeScreen controller for asynchronous workspace-memory browsing."

  use Gettext, backend: HandbeamProbe.Gettext
  import Mob.Socket, only: [assign: 3]

  alias HandbeamProbe.HomeScreen.{Async, Notice, Requests}
  alias HandbeamProbe.{NativeClipboard, WorkspaceMemory}

  @scope :workspace_memory

  def load(%{assigns: %{workspace: nil}} = socket), do: socket

  def load(socket) do
    state = WorkspaceMemory.loading(socket.assigns.workspace_memory)
    workspace_id = socket.assigns.workspace["id"]
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> assign(:workspace_memory, state)
    |> Async.run(:workspace_memory_loaded, fn -> WorkspaceMemory.fetch(workspace_id, state) end,
      scope: @scope,
      bump?: false
    )
  end

  def handle({:change, :memory_query, query}, socket) do
    reload(socket, WorkspaceMemory.set_query(socket.assigns.workspace_memory, query))
  end

  def handle({:tap, {:memory_scope, scope}}, socket) do
    reload(socket, WorkspaceMemory.set_scope(socket.assigns.workspace_memory, scope))
  end

  def handle({:tap, {:memory_lifecycle, lifecycle}}, socket) do
    reload(socket, WorkspaceMemory.set_lifecycle(socket.assigns.workspace_memory, lifecycle))
  end

  def handle({:tap, {:memory_kind, kind}}, socket) do
    reload(socket, WorkspaceMemory.set_kind(socket.assigns.workspace_memory, kind))
  end

  def handle({:tap, {:memory_related, id}}, socket) do
    reload(socket, WorkspaceMemory.locate(socket.assigns.workspace_memory, id))
  end

  def handle({:tap, {:memory_copy, field, id}}, socket) when field in [:id, :content] do
    case WorkspaceMemory.copy_value(socket.assigns.workspace_memory, id, field) do
      {:ok, value} ->
        socket
        |> NativeClipboard.put(value)
        |> Notice.put_info(copied_notice(field))

      :error ->
        socket
    end
  end

  def handle(_event, socket), do: socket

  def result(result, socket) do
    assign(
      socket,
      :workspace_memory,
      WorkspaceMemory.loaded(socket.assigns.workspace_memory, result)
    )
  end

  defp reload(socket, state) do
    socket
    |> assign(:workspace_memory, state)
    |> load()
  end

  defp copied_notice(:id), do: gettext("Memory ID copied")
  defp copied_notice(:content), do: gettext("Memory content copied")
end
