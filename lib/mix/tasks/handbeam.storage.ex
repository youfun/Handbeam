defmodule Mix.Tasks.Handbeam.Storage do
  use Mix.Task

  @shortdoc "Run SQLite diagnostics or create a verified online backup"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [backup: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix handbeam.storage [--backup PATH]")

    Mix.Task.run("app.start")

    result =
      case opts[:backup] do
        nil -> Handbeam.Storage.Diagnostics.check()
        path -> Handbeam.Storage.Diagnostics.backup(path)
      end

    case result do
      {:ok, report} -> Mix.shell().info(Handbeam.JSON.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("storage operation failed: #{inspect(reason)}")
    end
  end
end
