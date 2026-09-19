ExUnit.configure(exclude: [:slow, :e2e, :external_api])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, :manual)

# Start Tool Registry for agent/tool tests.
# If the app is already running, this is a no-op.
case Handbeam.Tool.Registry.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

unless Process.whereis(Handbeam.ExportSnapshot.Binding) do
  {:ok, _} = Handbeam.ExportSnapshot.Binding.start_link([])
end

# Start Extension Registry for hook/extension tests.
# If the app is already running, this is a no-op.
unless Process.whereis(Handbeam.Extension.Registry) do
  Handbeam.Extension.Registry.start_link(name: Handbeam.Extension.Registry)
end

unless Process.whereis(Handbeam.Extension.Supervisor) do
  Handbeam.Extension.Supervisor.start_link([])
end

unless Process.whereis(Handbeam.Extension.Mount) do
  Handbeam.Extension.Mount.start_link([])
end

unless Process.whereis(Handbeam.Workspace.MixOwner) do
  {:ok, _} = Handbeam.Workspace.MixOwner.start_link([])
end
