defmodule ExFff.Index do
  @moduledoc """
  GenServer that maintains the ETS-based file index.

  Manages three ETS tables per index instance:
  - Trigrams — trigram → path (:duplicate_bag)
  - Files — path → %{mtime, size} (:set)
  - Frecency — {score, path} → true (:ordered_set)

  ## Public API

  - `start_link/1` — start the GenServer (async index build)
  - `ensure_started/1` — start or retrieve index for root_path (multi-workspace aware)
  - `search/3` — search for files by query
  - `touch/2` — update frecency after tool access
  - `refresh/1` — full re-scan
  - `get_root/1` — retrieve current workspace root
  - `set_root/2` — switch workspace root and trigger re-index
  - `await_index/2` — wait until indexing is complete
  """

  use GenServer

  require Logger

  defstruct root_path: nil,
            config: nil,
            frecency_ref: nil,
            trigram_ref: nil,
            files_ref: nil,
            indexed_count: 0,
            status: :indexing,
            task: nil,
            generation: 0,
            pending_searches: [],
            index_started_at: nil,
            last_indexed_at: nil

  @typedoc false
  @type state :: %__MODULE__{
          root_path: String.t() | nil,
          config: ExFff.Config.t() | nil,
          frecency_ref: :ets.tid() | atom() | nil,
          trigram_ref: :ets.tid() | atom() | nil,
          files_ref: :ets.tid() | atom() | nil,
          indexed_count: non_neg_integer(),
          status: :indexing | :ready | :failed,
          task: Task.t() | nil,
          generation: non_neg_integer(),
          pending_searches: list(),
          index_started_at: integer() | nil,
          last_indexed_at: integer() | nil
        }

  # ── Public API ──

  def child_spec(opts) do
    name = opts[:name] || __MODULE__

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

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
  Ensure an Index GenServer is started for a given root path.

  Supports multi-workspace environments. If an index for the specified root path
  is already running, returns its PID. Otherwise starts a new instance under
  `ExFff.IndexSupervisor` (or linked directly if supervisor is unavailable).
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, String.t()}
  def ensure_started(root_path) when is_binary(root_path) do
    expanded = Path.expand(root_path)

    case lookup_index(expanded) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_index_for_root(expanded)
    end
  end

  @doc """
  Search for files matching the query.

  Options:
  - `:limit` — max results to return
  - `:await` — if true (default), waits for initial index build if in progress
  - `:timeout` — call timeout in ms (default 5000)

  Returns `{:ok, %{paths: [...], query: query, duration_ms: ms}}` or `{:error, reason}`.
  """
  @spec search(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def search(pid \\ __MODULE__, query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(pid, {:search, query, opts}, timeout)
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

  @doc """
  Get the configured root path of the index.
  """
  @spec get_root(GenServer.server()) :: {:ok, String.t()}
  def get_root(pid \\ __MODULE__) do
    GenServer.call(pid, :get_root)
  end

  @doc """
  Update the root path and trigger a re-index.
  """
  @spec set_root(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def set_root(pid \\ __MODULE__, root_path) do
    GenServer.call(pid, {:set_root, root_path})
  end

  @doc """
  Wait until the index build has completed.
  """
  @spec await_index(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_index(pid \\ __MODULE__, timeout \\ 5000) do
    GenServer.call(pid, :await_index, timeout)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

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

      # Create isolated ETS tables per index instance
      trigram_tab =
        :ets.new(:ex_fff_trigrams, [:duplicate_bag, :public, {:read_concurrency, true}])

      files_tab = :ets.new(:ex_fff_files, [:set, :public, {:read_concurrency, true}])

      frecency_tab =
        :ets.new(:ex_fff_frecency, [:ordered_set, :public, {:read_concurrency, true}])

      state = %__MODULE__{
        root_path: root_path,
        config: config,
        trigram_ref: trigram_tab,
        files_ref: files_tab,
        frecency_ref: frecency_tab,
        indexed_count: 0,
        status: :indexing,
        task: nil,
        generation: 0,
        pending_searches: [],
        index_started_at: nil,
        last_indexed_at: nil
      }

      state = start_indexing(state)

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:search, query_string, opts}, from, state) do
    cond do
      state.status == :failed ->
        {:reply, {:error, "Indexing failed for #{state.root_path}"}, state}

      state.status == :indexing and Keyword.get(opts, :await, true) ->
        pending = {from, query_string, opts, state.generation}
        {:noreply, %{state | pending_searches: [pending | state.pending_searches]}}

      true ->
        {:reply, do_search(query_string, opts, state), state}
    end
  end

  @impl true
  def handle_call(:await_index, from, state) do
    case state.status do
      :ready ->
        {:reply, :ok, state}

      :failed ->
        {:reply, {:error, "Indexing failed for #{state.root_path}"}, state}

      :indexing ->
        pending = {from, :await_index, [], state.generation}
        {:noreply, %{state | pending_searches: [pending | state.pending_searches]}}
    end
  end

  @impl true
  def handle_call(:get_root, _from, state) do
    {:reply, {:ok, state.root_path}, state}
  end

  @impl true
  def handle_call({:set_root, root_path}, _from, state) do
    expanded = Path.expand(root_path)

    if !File.dir?(expanded) do
      {:reply, {:error, "root_path is not a directory: #{root_path}"}, state}
    else
      state = cancel_indexing(state, {:error, "index root changed"})
      clear_tables(state)

      config = %{state.config | root_path: expanded}

      new_state = %{
        state
        | root_path: expanded,
          config: config,
          indexed_count: 0,
          status: :indexing,
          task: nil
      }

      {:reply, :ok, start_indexing(new_state)}
    end
  end

  @impl true
  def handle_call(:get_counts, _from, state) do
    files_size = if state.files_ref, do: :ets.info(state.files_ref, :size) || 0, else: 0
    trigrams_size = if state.trigram_ref, do: :ets.info(state.trigram_ref, :size) || 0, else: 0
    frecency_size = if state.frecency_ref, do: :ets.info(state.frecency_ref, :size) || 0, else: 0

    counts = %{
      files: files_size,
      trigrams: trigrams_size,
      frecency: frecency_size
    }

    {:reply, {:ok, counts}, state}
  end

  @impl true
  def handle_cast({:touch, path}, state) do
    if :ets.member(state.files_ref, path) do
      objects = :ets.match_object(state.frecency_ref, {{:_, path}, :_})

      score =
        case objects do
          [] -> 0.0
          [{{s, _p}, _v} | _] -> s
        end

      new_score = ExFff.Matcher.compute_frecency(score)

      :ets.match_delete(state.frecency_ref, {{:_, path}, :_})
      :ets.insert(state.frecency_ref, {{new_score, path}, true})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, start_indexing(state)}
  end

  @impl true
  def handle_info(:build_index, state) do
    {:noreply, start_indexing(state)}
  end

  @impl true
  def handle_info(
        {ref, {:ok, generation, count, files_entries, trig_entries}},
        %{task: %Task{ref: ref}, generation: generation} = state
      ) do
    Process.demonitor(ref, [:flush])

    :ets.delete_all_objects(state.files_ref)
    :ets.delete_all_objects(state.trigram_ref)

    if files_entries != [], do: :ets.insert(state.files_ref, files_entries)
    if trig_entries != [], do: :ets.insert(state.trigram_ref, trig_entries)

    prune_frecency(state.frecency_ref, state.files_ref)

    elapsed =
      if state.index_started_at do
        System.monotonic_time(:millisecond) - state.index_started_at
      else
        0
      end

    Logger.info("[ExFff.Index] Indexed #{count} files in #{elapsed}ms for #{state.root_path}")

    new_state = %{
      state
      | indexed_count: count,
        status: :ready,
        task: nil,
        index_started_at: nil,
        last_indexed_at: System.system_time(:second)
    }

    {:noreply, flush_pending_searches(new_state, generation)}
  end

  def handle_info({:index_failed, generation, reason}, state) do
    fail_indexing(state, generation, reason)
  end

  def handle_info({ref, {:error, generation, reason}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    fail_indexing(state, generation, reason)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # A matching result message is handled above and demonitors with :flush.
    # Reaching here means the task died without a usable result.
    fail_indexing(state, state.generation, reason)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{task: %Task{pid: pid}} = state) do
    fail_indexing(state, state.generation, reason)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    :ok
  end

  # ── Internal Functions ──

  defp start_indexing(state) do
    state = if state.task, do: cancel_indexing(state, {:error, "index restarted"}), else: state
    clear_tables(state)
    generation = state.generation + 1
    root = state.root_path
    config = state.config

    Logger.info("[ExFff.Index] Building file index for #{root}...")
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        case ExFff.Scanner.scan_and_prepare(root, config) do
          {:ok, count, files_entries, trig_entries} ->
            {:ok, generation, count, files_entries, trig_entries}

          {:error, reason} ->
            {:error, generation, reason}
        end
      end)

    %{
      state
      | task: task,
        generation: generation,
        status: :indexing,
        indexed_count: 0,
        index_started_at: started_at
    }
  end

  defp cancel_indexing(state, reply) do
    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    reply_pending(state.pending_searches, state.generation, reply)
    %{state | task: nil, pending_searches: []}
  end

  defp fail_indexing(state, generation, reason) do
    Logger.error(
      "[ExFff.Index] Indexing task failed for #{state.root_path}: #{inspect(reason)}"
    )

    if generation == state.generation do
      reply_pending(state.pending_searches, generation, {:error, "Indexing failed: #{inspect(reason)}"})

      {:stop, {:indexing_failed, reason},
       %{
         state
         | task: nil,
           status: :failed,
           pending_searches: [],
           index_started_at: nil
       }}
    else
      {:noreply, %{state | task: nil}}
    end
  end

  defp clear_tables(state) do
    :ets.delete_all_objects(state.files_ref)
    :ets.delete_all_objects(state.trigram_ref)
    :ets.delete_all_objects(state.frecency_ref)
  end

  defp reply_pending(pending, generation, reply) do
    for {from, _kind, _opts, pending_generation} <- pending,
        pending_generation == generation do
      GenServer.reply(from, reply)
    end
  end

  defp prune_frecency(frecency_ref, files_ref) do
    :ets.foldl(
      fn {{_score, path}, _value}, acc ->
        unless :ets.member(files_ref, path) do
          :ets.match_delete(frecency_ref, {{:_, path}, :_})
        end

        acc
      end,
      :ok,
      frecency_ref
    )
  end

  defp do_search(query_string, opts, state) do
    start_time = System.monotonic_time(:millisecond)
    parsed_query = ExFff.Query.parse(query_string)

    limit = Keyword.get(opts, :limit, parsed_query.limit)
    parsed_query = %{parsed_query | limit: max(limit, 1)}

    results =
      ExFff.Matcher.match(
        parsed_query,
        state.files_ref,
        state.trigram_ref,
        state.frecency_ref
      )

    duration_ms = System.monotonic_time(:millisecond) - start_time

    {:ok,
     %{
       paths: results,
       query: query_string,
       duration_ms: duration_ms
     }}
  end

  defp flush_pending_searches(state, generation) do
    {current, stale} =
      Enum.split_with(state.pending_searches, fn {_from, _kind, _opts, pending_generation} ->
        pending_generation == generation
      end)

    reply_pending(stale, generation - 1, {:error, "index restarted"})

    for item <- Enum.reverse(current) do
      case item do
        {from, :await_index, _opts, ^generation} ->
          GenServer.reply(from, :ok)

        {from, query_string, opts, ^generation} ->
          GenServer.reply(from, do_search(query_string, opts, state))
      end
    end

    %{state | pending_searches: []}
  end

  # ── Multi-Workspace Registry & Lookup ──

  defp lookup_index(root) do
    case Process.whereis(ExFff.Registry) do
      nil ->
        :not_found

      _reg ->
        case Registry.lookup(ExFff.Registry, root) do
          [{pid, _value}] ->
            if Process.alive?(pid), do: {:ok, pid}, else: :not_found

          [] ->
            :not_found
        end
    end
  end

  defp start_index_for_root(root) do
    case Process.whereis(ExFff.IndexSupervisor) do
      nil ->
        case start_link(root_path: root) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, "Failed to start ExFff.Index: #{inspect(reason)}"}
        end

      _sup ->
        child_spec = {
          __MODULE__,
          [root_path: root, name: {:via, Registry, {ExFff.Registry, root}}]
        }

        case DynamicSupervisor.start_child(ExFff.IndexSupervisor, child_spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, "Failed to start ExFff.Index: #{inspect(reason)}"}
        end
    end
  end
end
