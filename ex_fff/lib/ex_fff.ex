defmodule ExFff do
  @moduledoc """
  ExFff — ETS-based fuzzy file finder.

  Fast in-memory file search engine using ETS tables for trigram indexing
  and frecency scoring. Designed as a drop-in replacement for `rg`-based
  file search in AI coding assistants.

  ## Usage

      # Start the index GenServer
      {:ok, pid} = ExFff.Index.start_link(root_path: "/my/project")

      # Search for files
      {:ok, result} = ExFff.search("user controller ex")
      result.paths  # => [%{path: "lib/user_controller.ex", score: 95.2}, ...]

      # Record file access to boost frecency
      ExFff.Index.touch(pid, "lib/user_controller.ex")

      # Refresh the full index
      ExFff.Index.refresh(pid)

  ## Architecture

  Three ETS tables power the engine:

  - `ExFff.Trigrams` (`:duplicate_bag`) — trigram → path mapping for
    fast candidate lookup
  - `ExFff.Files` (`:set`) — path → %{mtime, size} for file metadata
  - `ExFff.Frecency` (`:ordered_set`) — `{score, path}` → true for
    recency-weighted ranking

  The GenServer is supervised by `ExFff.Application`.
  """

  @doc """
  Convenience function: search the workspace using the registered Index GenServer.

  Returns `{:ok, %ExFff.Query.Result{}}` or `{:error, reason}`.
  """
  @spec search(binary(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def search(query, opts \\ []) do
    ExFff.Index.search(ExFff.Index, query, opts)
  end
end
