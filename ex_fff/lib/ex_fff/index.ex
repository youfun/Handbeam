defmodule ExFff.Index do
  @moduledoc """
  GenServer that maintains the ETS-based file index.

  Manages three ETS tables:
  - `ExFff.Trigrams` — trigram → path (:duplicate_bag)
  - `ExFff.Files` — path → %{mtime, size} (:set)
  - `ExFff.Frecency` — {score, path} → true (:ordered_set)

  ## Public API

  - `start_link/1` — start the GenServer (async index build)
  - `search/3` — search for files by query
  - `touch/2` — update frecency after tool access
  - `refresh/1` — full re-scan
  - `ensure_started/1` — start if not already running
  """

  use GenServer

  require Logger

  @trigram_tab ExFff.Trigrams
  @files_tab ExFff.Files
  @frecency_tab ExFff.Frecency

  defstruct root_path: nil,
            config: nil,
            frecency_ref: nil,
            trigram_ref: nil,
            files_ref: nil,
            indexed_count: 0

  @typedoc false
  @type state :: %__MODULE__{
          root_path: String.t() | nil,
          config: ExFff.Config.t() | nil,
          frecency_ref: reference() | nil,
          trigram_ref: reference() | nil,
          files_ref: reference() | nil,
          indexed_count: non_neg_integer()
        }

  # ── Public API ──

  @doc """
  Start the Index GenServer.

  Options:
  - `:root_path` — project root to scan (required)
  - `:max_files` — max files to index (default 50_000)
  - `:ignore_patterns` — additional regex patterns to ignore
  - `:name` — GenServer name (default `__MODULE__`)

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensure the Index GenServer is started for a given root path.

  If already running and alive, returns `{:ok, pid}`.
  Otherwise starts a new instance and returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, String.t()}
  def ensure_started(root_path) when is_binary(root_path) do
    existing = Process.whereis(__MODULE__)

    if existing && Process.alive?(existing) do
      {:ok, existing}
    else
      case start_link(root_path: root_path) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, "Failed to start ExFff.Index: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Search for files matching the query.

  Returns `{:ok, %{paths: [...], query: query, duration_ms: ms}}` or `{:error, reason}`.
  """
  @spec search(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def search(pid \\ __MODULE__, query, opts \\ []) do
    GenServer.call(pid, {:search, query, opts})
  end

  @doc """
  Touch a file path to boost its frecency score.

  Call after a tool successfully operates on a file.
  """
  @spec touch(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def touch(pid \\ __MODULE__, path) do
    GenServer.cast(pid, {:touch, path})
  end

  @doc """
  Trigger a full index refresh (rescan all files).
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(pid \\ __MODULE__) do
    GenServer.cast(pid, :refresh)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    root_path = Keyword.fetch!(opts, :root_path)

    if !File.dir?(root_path) do
      {:stop, "root_path is not a directory: #{root_path}"}
    else
      config =
        ExFff.Config.new(
          root_path: root_path,
          max_files: Keyword.get(opts, :max_files, 50_000),
          ignore_patterns: Keyword.get(opts, :ignore_patterns, ExFff.Config.new().ignore_patterns)
        )

      # Create ETS tables
      trigram_tab = ensure_table(@trigram_tab, :duplicate_bag)
      files_tab = ensure_table(@files_tab, :set)
      frecency_tab = ensure_table(@frecency_tab, :ordered_set)

      state = %__MODULE__{
        root_path: root_path,
        config: config,
        trigram_ref: trigram_tab,
        files_ref: files_tab,
        frecency_ref: frecency_tab,
        indexed_count: 0
      }

      # Async index build
      send(self(), :build_index)

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:search, query_string, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    parsed_query = ExFff.Query.parse(query_string)

    limit = Keyword.get(opts, :limit, parsed_query.limit)
    parsed_query = %{parsed_query | limit: max(limit, 1)}

    results =
      ExFff.Matcher.match(
        parsed_query,
        @files_tab,
        @trigram_tab,
        @frecency_tab
      )

    duration_ms = System.monotonic_time(:millisecond) - start_time

    result = %{
      paths: results,
      query: query_string,
      duration_ms: duration_ms
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_counts, _from, state) do
    counts = %{
      files: :ets.info(@files_tab, :size),
      trigrams: :ets.info(@trigram_tab, :size),
      frecency: :ets.info(@frecency_tab, :size)
    }

    {:reply, {:ok, counts}, state}
  end

  @impl true
  def handle_cast({:touch, path}, state) do
    # Use match_object for proper wildcard matching
    objects = :ets.match_object(@frecency_tab, {{:_, path}, :_})

    score =
      case objects do
        [] -> 0.0
        [{{s, _p}, _v} | _] -> s
      end

    new_score = ExFff.Matcher.compute_frecency(score)

    # Remove old entry, insert new one
    :ets.match_delete(@frecency_tab, {{:_, path}, :_})
    :ets.insert(@frecency_tab, {{new_score, path}, true})

    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :build_index)
    {:noreply, state}
  end

  @impl true
  def handle_info(:build_index, state) do
    state = build_index(state)
    {:noreply, state}
  end

  # ── Index Building ──

  defp build_index(state) do
    Logger.info("[ExFff.Index] Building file index for #{state.root_path}...")
    start_time = System.monotonic_time(:millisecond)

    # Clear existing tables
    :ets.delete_all_objects(@trigram_tab)
    :ets.delete_all_objects(@files_tab)

    root = state.root_path
    config = state.config
    pattern = Path.join(root, "**/*")

    files =
      pattern
      |> Path.wildcard()
      |> Enum.filter(&regular_file?/1)
      |> Enum.reject(fn path ->
        # Defensive: skip non-UTF-8 paths and skip ignored paths.
        # Using try/rescue because Regex matching can blow up on
        # invalid UTF-8 binaries (e.g. exotic filesystem encodings).
        try do
          relative = Path.relative_to(path, root)
          not String.valid?(relative) or ExFff.Config.ignored?(config, relative)
        rescue
          _ -> true
        end
      end)
      |> Enum.take(config.max_files)

    indexed =
      Enum.reduce(files, 0, fn path, acc ->
        try do
          index_one_file(path, root)
        rescue
          e ->
            Logger.debug(
              "[ExFff.Index] skipping #{inspect(path)}: #{Exception.message(e)}"
            )

            false
        catch
          kind, reason ->
            Logger.debug(
              "[ExFff.Index] skipping #{inspect(path)}: #{inspect({kind, reason})}"
            )

            false
        end
        |> case do
          true -> acc + 1
          false -> acc
        end
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("[ExFff.Index] Indexed #{indexed} files in #{elapsed}ms")

    %{state | indexed_count: indexed}
  end

  # ── Helpers ──

  # Index a single file. Returns `true` on success, `false` when the
  # file is not stat-able or its path/name is not valid UTF-8.
  #
  # Wrapped by the caller in `try/rescue/catch` so that any unexpected
  # failure (e.g. an exotic non-UTF-8 path slipping past `String.valid?`)
  # only drops a single file instead of crashing the whole indexer.
  defp index_one_file(path, root) do
    relative = Path.relative_to(path, root)

    cond do
      not String.valid?(relative) ->
        false

      true ->
        case File.stat(path) do
          {:ok, stat} ->
            :ets.insert(@files_tab, {relative, %{mtime: stat.mtime, size: stat.size}})

            lower_relative = String.downcase(relative)
            trigrams = ExFff.Matcher.tokenize(lower_relative)

            case Enum.map(trigrams, fn t -> {t, relative} end) do
              [] -> :ok
              entries -> :ets.insert(@trigram_tab, entries)
            end

            true

          {:error, _reason} ->
            false
        end
    end
  end

  defp ensure_table(name, type) do
    case :ets.info(name, :name) do
      :undefined ->
        :ets.new(name, [:named_table, :protected, type])

      _ ->
        # Table exists; check it's the right type
        name
    end
  end

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> true
      _ -> false
    end
  end
end
