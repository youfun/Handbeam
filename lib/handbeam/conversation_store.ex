defmodule Handbeam.ConversationStore do
  @moduledoc """
  JSON-backed conversation storage — one directory per conversation.

  Stores conversations under `~/.handbeam/conversations/` by default:

      ~/.handbeam/conversations/
      ├── index.json
      └── items/
          └── <conversation_id>/
              ├── meta.json
              ├── messages.jsonl
              └── files.json

  Conversation storage is fixed at `~/.handbeam/conversations/`.
  Workspace storage is configuration only and does not affect conversation
  paths.
  """

  require Logger

  @type conversation :: map()

  # ── Path helpers ────────────────────────────────────────────────────────

  @doc """
  Return the storage directory for conversations.

  Conversations always live under `~/.handbeam/conversations/`; the index file is
  `~/.handbeam/conversations/index.json`.
  """
  @spec storage_dir :: String.t()
  def storage_dir do
    home = Handbeam.Home.path()
    Path.join([Path.expand(home), ".handbeam", "conversations"])
  end

  @doc "Return the path to the index JSON file."
  @spec storage_path :: String.t()
  def storage_path, do: index_path()

  @doc "Return the path to the index JSON file."
  @spec index_path :: String.t()
  def index_path, do: Path.join(storage_dir(), "index.json")

  @doc """
  Return the path to a conversation item.

  **Breaking change:** previously returned `items/<id>.json` (a file);
  now returns `items/<id>/` (a directory). Use `conversation_dir/1`,
  `meta_path/1`, `messages_path/1`, or `files_path/1` for precise paths.
  """
  @spec item_path(String.t()) :: String.t()
  def item_path(conversation_id) when is_binary(conversation_id) do
    conversation_dir(conversation_id)
  end

  @doc "Return the directory path for a conversation."
  @spec conversation_dir(String.t()) :: String.t()
  def conversation_dir(conversation_id) when is_binary(conversation_id) do
    storage_dir() |> Path.join("items") |> Path.join(conversation_id)
  end

  @doc "Return the path to a conversation's meta.json."
  @spec meta_path(String.t()) :: String.t()
  def meta_path(conversation_id) when is_binary(conversation_id) do
    conversation_dir(conversation_id) |> Path.join("meta.json")
  end

  @doc "Return the path to a conversation's messages.jsonl."
  @spec messages_path(String.t()) :: String.t()
  def messages_path(conversation_id) when is_binary(conversation_id) do
    conversation_dir(conversation_id) |> Path.join("messages.jsonl")
  end

  @doc "Return the path to a conversation's files.json."
  @spec files_path(String.t()) :: String.t()
  def files_path(conversation_id) when is_binary(conversation_id) do
    conversation_dir(conversation_id) |> Path.join("files.json")
  end

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "List every persisted conversation (full objects for backward compat)."
  @spec list :: [conversation()]
  def list(opts \\ []) do
    with {:ok, index} <- read_index() do
      entries = Map.get(index, "conversations", [])

      dev_log(
        "[ConversationStore] list index=#{index_path()} entries=#{length(entries)} " <>
          "ids=#{inspect(Enum.map(entries, & &1["id"]))}"
      )

      entries
      |> Enum.map(&load_from_index_entry(&1, opts))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(not Keyword.get(opts, :include_internal?, false) and internal?(&1)))
    else
      {:error, :not_found} ->
        dev_log("[ConversationStore] list index not found path=#{index_path()}")
        []

      {:error, reason} ->
        dev_log(
          "[ConversationStore] list index unreadable (#{inspect(reason)}) path=#{index_path()}"
        )

        []
    end
  end

  @doc "List conversations for a workspace id."
  @spec list_for_workspace(String.t()) :: [conversation()]
  def list_for_workspace(workspace_id) do
    list_for_workspace(workspace_id, include_archived?: false)
  end

  @doc """
  List conversations for a workspace id.

  Options:
    - `:include_archived?` (default false) — include archived conversations
  """
  @spec list_for_workspace(String.t(), keyword()) :: [conversation()]
  def list_for_workspace(workspace_id, opts) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    list(opts)
    |> Enum.filter(&(&1["workspace_id"] == workspace_id and not free?(&1)))
    |> maybe_filter_archived(include_archived?)
    |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
  end

  @doc "Read workspace metadata without loading transcripts or editor files."
  def list_metadata(workspace_id) do
    case read_index() do
      {:ok, index} ->
        index
        |> Map.get("conversations", [])
        |> Enum.filter(&(&1["workspace_id"] == workspace_id and not free?(&1)))
        |> Enum.flat_map(fn entry ->
          case get_metadata(entry["id"]) do
            {:ok, %{"workspace_id" => ^workspace_id} = meta} ->
              if free?(meta), do: [], else: [meta]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  List workspace-independent chats.

  Options:
    - `:include_archived?` (default false)
    - `:include_timeline?` (default true) — passed through to `list/1`
  """
  @spec list_free(keyword()) :: [conversation()]
  def list_free(opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    list(opts)
    |> Enum.filter(&free?/1)
    |> maybe_filter_archived(include_archived?)
    |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
  end

  @doc "Read only persisted conversation metadata. IDs must be path-safe."
  def get_metadata(id) when is_binary(id) do
    if byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
      do: read_meta(id),
      else: {:error, :not_found}
  end

  def get_metadata(_), do: {:error, :not_found}

  @doc "Get one conversation by id."
  @spec get(String.t()) :: {:ok, conversation()} | {:error, :not_found}
  def get(id, opts \\ []) when is_binary(id) do
    case read_item(id, opts) do
      {:ok, conversation} ->
        if accessible?(conversation, opts), do: {:ok, conversation}, else: {:error, :not_found}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  def internal?(%{"visibility" => "internal"}), do: true

  def internal?(id) when is_binary(id) do
    case read_meta(id) do
      {:ok, meta} -> internal?(meta)
      _ -> false
    end
  end

  def internal?(_), do: false

  defp accessible?(conversation, opts) do
    context = Keyword.get(opts, :access_context, %{})

    not internal?(conversation) or
      (conversation["parent_conversation_id"] == context[:conversation_id] and
         conversation["parent_run_id"] == context[:run_id] and
         conversation["workspace_id"] == context[:workspace_id] and
         Handbeam.Agent.Delegation.Policy.live_parent?(context))
  end

  @doc false
  def authorize_read(id, opts) do
    with {:ok, meta} <- read_meta(id),
         true <- accessible?(meta, opts) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Read only a conversation's metadata, without loading transcript or editor files."
  @spec get_meta(String.t()) :: {:ok, map()} | {:error, :not_found | :corrupted | term()}
  def get_meta(id) when is_binary(id), do: read_meta(id)

  @doc "Return whether a conversation metadata record exists and is readable."
  @spec exists?(String.t()) :: boolean()
  def exists?(id) when is_binary(id), do: match?({:ok, _}, read_meta(id))

  @doc """
  Create a new conversation for a workspace.

  Free chats are created with `create_free/1` and persist `scope: "free"`
  with no `workspace_id`. Existing records without `scope` stay workspace chats.
  """
  @spec create(String.t(), keyword()) :: {:ok, conversation()} | {:error, term()}
  def create(workspace_id, opts \\ []) when is_binary(workspace_id) do
    now = now_iso8601()

    conversation = %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "scope" => "workspace",
      "workspace_id" => workspace_id,
      "visibility" => Keyword.get(opts, :visibility, "user"),
      "parent_conversation_id" => Keyword.get(opts, :parent_conversation_id),
      "parent_run_id" => Keyword.get(opts, :parent_run_id),
      "parent_tool_call_id" => Keyword.get(opts, :parent_tool_call_id),
      "title" => Keyword.get(opts, :title, "New chat"),
      "title_source" => Keyword.get(opts, :title_source, "manual"),
      "timeline" => Keyword.get(opts, :timeline, []),
      "editor_files" => Keyword.get(opts, :editor_files, []),
      "active_file" => Keyword.get(opts, :active_file),
      "file_preview_error" => Keyword.get(opts, :file_preview_error),
      "selected_model" => Keyword.get(opts, :selected_model),
      "collaboration" => Keyword.get(opts, :collaboration),
      "selected_reasoning_level" => Keyword.get(opts, :selected_reasoning_level),
      "archived_at" => Keyword.get(opts, :archived_at),
      "created_at" => now,
      "updated_at" => now
    }

    upsert(conversation)
  end

  @doc """
  Create a workspace-independent chat.

  The record has `scope: "free"` and `workspace_id: nil`. It is omitted from
  `list_for_workspace/2` and `list_metadata/1`.
  """
  @spec create_free(keyword()) :: {:ok, conversation()} | {:error, term()}
  def create_free(opts \\ []) do
    now = now_iso8601()

    conversation = %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "scope" => "free",
      "workspace_id" => nil,
      "visibility" => Keyword.get(opts, :visibility, "user"),
      "parent_conversation_id" => Keyword.get(opts, :parent_conversation_id),
      "parent_run_id" => Keyword.get(opts, :parent_run_id),
      "parent_tool_call_id" => Keyword.get(opts, :parent_tool_call_id),
      "title" => Keyword.get(opts, :title, "New chat"),
      "title_source" => Keyword.get(opts, :title_source, "manual"),
      "timeline" => Keyword.get(opts, :timeline, []),
      "editor_files" => Keyword.get(opts, :editor_files, []),
      "active_file" => Keyword.get(opts, :active_file),
      "file_preview_error" => Keyword.get(opts, :file_preview_error),
      "selected_model" => Keyword.get(opts, :selected_model),
      "collaboration" => Keyword.get(opts, :collaboration),
      "selected_reasoning_level" => Keyword.get(opts, :selected_reasoning_level),
      "archived_at" => Keyword.get(opts, :archived_at),
      "created_at" => now,
      "updated_at" => now
    }

    upsert(conversation)
  end

  @doc "True when the conversation is a workspace-independent chat."
  @spec free?(map() | String.t()) :: boolean()
  def free?(%{"scope" => "free"}), do: true
  def free?(%{"scope" => :free}), do: true
  def free?(%{scope: "free"}), do: true
  def free?(%{scope: :free}), do: true

  def free?(id) when is_binary(id) do
    case read_meta(id) do
      {:ok, meta} -> free?(meta)
      _ -> false
    end
  end

  def free?(_), do: false

  @doc """
  Archive a conversation by id.

  Archiving hides the conversation from the default list, but it can be restored
  later and continued.
  """
  @spec archive(String.t()) :: {:ok, conversation()} | {:error, :not_found | term()}
  def archive(id) when is_binary(id) do
    with {:ok, conversation} <- get(id) do
      upsert(Map.put(conversation, "archived_at", now_iso8601()))
    end
  end

  @doc """
  Restore (unarchive) a conversation by id.
  """
  @spec unarchive(String.t()) :: {:ok, conversation()} | {:error, :not_found | term()}
  def unarchive(id) when is_binary(id) do
    with {:ok, conversation} <- get(id) do
      upsert(Map.put(conversation, "archived_at", nil))
    end
  end

  @title_max_length 80

  @doc """
  Rename a conversation and mark the title as manual.

  A manual title is not overwritten by auto title generation. Empty titles
  and titles longer than #{@title_max_length} characters are rejected.
  """
  @spec rename(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :empty | :too_long | term()}
  def rename(id, title) when is_binary(id) and is_binary(title) do
    with {:ok, normalized} <- normalize_title(title),
         {:ok, meta} <- update_meta(id, title: normalized, title_source: "manual") do
      broadcast_title_updated(id)
      {:ok, meta}
    end
  end

  @doc false
  @spec normalize_title(String.t()) :: {:ok, String.t()} | {:error, :empty | :too_long}
  def normalize_title(title) when is_binary(title) do
    normalized =
      title
      |> String.replace(~r/[\r\n\t]+/u, " ")
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      normalized == "" -> {:error, :empty}
      String.length(normalized) > @title_max_length -> {:error, :too_long}
      true -> {:ok, normalized}
    end
  end

  @doc false
  def broadcast_title_updated(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      Handbeam.PubSub,
      "conversation:updated",
      {:conversation_updated, conversation_id}
    )
  end

  @doc "Insert or replace a conversation."
  @spec upsert(conversation()) :: {:ok, conversation()} | {:error, term()}
  def upsert(conversation) when is_map(conversation) do
    conversation =
      case get_metadata(value(conversation, "id")) do
        {:ok, meta} ->
          Enum.reduce(
            ~w(collaboration visibility last_run_result),
            conversation,
            fn key, acc ->
              Map.put(acc, key, meta[key])
            end
          )

        _ ->
          conversation
      end

    normalized = normalize_conversation(conversation)

    with {:ok, normalized} <- merge_owned_meta(normalized),
         :ok <- write_item(normalized),
         :ok <- sync_index_entry(normalized) do
      {:ok, normalized}
    end
  end

  defp merge_owned_meta(normalized) do
    case read_meta(normalized["id"]) do
      {:ok, existing} ->
        {:ok,
         Map.merge(
           normalized,
           Map.take(
             existing,
             ~w(visibility parent_conversation_id parent_run_id parent_tool_call_id delegated_usage)
           )
         )}

      {:error, reason} when reason in [:not_found, :corrupted] ->
        {:ok, normalized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Ensure every workspace has at least one conversation and return grouped conversations."
  @spec ensure_for_workspaces([map()]) :: %{String.t() => [conversation()]}
  def ensure_for_workspaces(workspaces) do
    Enum.reduce(workspaces, %{}, fn workspace, acc ->
      workspace_id = workspace["id"]
      conversations = list_for_workspace(workspace_id)

      conversations =
        if conversations == [] do
          {:ok, conversation} = create(workspace_id)
          [conversation]
        else
          conversations
        end

      Map.put(acc, workspace_id, conversations)
    end)
  end

  # ── New message API ─────────────────────────────────────────────────────

  @doc """
  Append a single message entry to messages.jsonl.

  Only works for conversations that already exist (meta.json must be present).
  Returns `{:error, :not_found}` for unknown conversation ids.
  """
  @spec append_message(String.t(), map()) :: :ok | {:error, term()}
  def append_message(conversation_id, entry) when is_map(entry) do
    with {:ok, _meta} <- read_meta(conversation_id) do
      case Handbeam.ConversationTranscriptStore.Journal.append(
             messages_path(conversation_id),
             entry
           ) do
        {:ok, _entry} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Load all messages from messages.jsonl for a conversation."
  @spec load_messages(String.t()) :: [map()]
  def load_messages(conversation_id) when is_binary(conversation_id) do
    case load_messages_result(conversation_id) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        Logger.error(
          "[ConversationStore] Error reading messages #{messages_path(conversation_id)}: #{inspect(reason)}"
        )

        []
    end
  end

  @doc "Load messages while preserving filesystem and corruption errors."
  @spec load_messages_result(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load_messages_result(conversation_id) when is_binary(conversation_id) do
    Handbeam.ConversationTranscriptStore.Journal.load(messages_path(conversation_id))
  end

  @doc """
  Replace all messages in messages.jsonl for a conversation.

  Only works for conversations that already exist (meta.json must be present).
  If any entry fails to encode as JSON the entire operation returns
  `{:error, :encode_failed}` — no partial write is performed.
  """
  @spec replace_messages(String.t(), [map()]) :: :ok | {:error, term()}
  def replace_messages(conversation_id, entries) when is_list(entries) do
    with {:ok, _meta} <- read_meta(conversation_id) do
      encoded =
        entries |> Enum.map(&Handbeam.JsonSafe.normalize/1) |> Enum.map(&Handbeam.JSON.encode/1)

      if error = Enum.find(encoded, &match?({:error, _}, &1)) do
        Logger.error(
          "[ConversationStore] Failed to encode entry in replace_messages for #{conversation_id}: #{inspect(error)}"
        )

        {:error, :encode_failed}
      else
        Handbeam.ConversationTranscriptStore.Journal.replace(
          messages_path(conversation_id),
          Enum.map(entries, &Handbeam.JsonSafe.normalize/1)
        )
      end
    end
  end

  @doc "Load editor files state from files.json for a conversation."
  @spec load_files(String.t()) :: %{
          optional(String.t()) => String.t() | [map()] | nil
        }
  def load_files(conversation_id) when is_binary(conversation_id) do
    path = files_path(conversation_id)

    case storage_read(path) do
      {:ok, content} when content == "" ->
        %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}

      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, data} when is_map(data) ->
            data

          {:ok, _} ->
            %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}

          {:error, _} ->
            Logger.warning(fn ->
              "[ConversationStore] Corrupted files.json for #{conversation_id}"
            end)

            %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}
        end

      {:error, :enoent} ->
        %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}

      {:error, reason} ->
        Logger.error("[ConversationStore] Error reading files #{path}: #{inspect(reason)}")

        %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}
    end
  end

  @doc """
  Save editor files state to files.json for a conversation.

  Only works for conversations that already exist (meta.json must be present).
  """
  @spec save_files(String.t(), map()) :: :ok | {:error, term()}
  def save_files(conversation_id, files_data) when is_map(files_data) do
    with {:ok, _meta} <- read_meta(conversation_id) do
      atomic_write_json(files_path(conversation_id), files_data)
    end
  end

  @doc """
  Update meta fields for a conversation without touching messages or files.

  Returns `{:ok, meta_map}` on success — the returned map contains meta fields
  only (id, title, workspace_id, etc.), **not** the full conversation.
  Use `get/1` to obtain the full conversation after updating meta.
  """
  @usage_meta_keys ~w(token_usage run_usage usage_legacy run_usage_replace)

  @spec update_meta(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def update_meta(id, updates) when is_binary(id) and is_list(updates) do
    ensure_conversation_dir(id)

    with {:ok, merged} <-
           transact_meta(id, fn existing ->
             updates
             |> Enum.reject(fn {key, _} -> to_string(key) in @usage_meta_keys end)
             |> Enum.reduce(existing, fn {key, value}, acc ->
               Map.put(acc, to_string(key), value)
             end)
             |> Map.put("updated_at", now_iso8601())
           end),
         :ok <- sync_index_entry(merged) do
      {:ok, merged}
    end
  end

  @doc """
  Read the conversation-level token totals from meta.json.

  Totals are derived from `run_usage` plus any pre-`run_usage` baseline.
  A meta file that only has `token_usage` still returns that original total.
  `usage_incomplete` is true when a recorded run did not report usage; the
  numbers are not a silent zero measurement in that case.
  """
  @spec get_token_usage(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_token_usage(conversation_id)
      when is_binary(conversation_id) and conversation_id != "" do
    case read_meta(conversation_id) do
      {:ok, meta} -> {:ok, usage_view(combined_usage(meta))}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_token_usage(_), do: {:ok, empty_token_usage()}

  @doc """
  Add usage that is not keyed by run id.

  The read-modify-write happens inside the meta lock. Prefer
  `record_run_usage/3` for run totals so a repeated `run_id` counts once.
  """
  @spec add_token_usage(String.t(), map()) :: :ok | {:error, :not_found | term()}
  def add_token_usage(conversation_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_map(usage) do
    delta = normalize_usage(usage)

    with {:ok, _meta} <-
           transact_meta(conversation_id, fn existing ->
             Map.put(existing, "usage_legacy", sum_stored(explicit_legacy(existing), delta))
           end) do
      :ok
    end
  end

  @doc """
  Store one run's usage under `run_id`. A second write of the same id does not
  add again. `token_usage` is recomputed from the per-run map.
  """
  @spec record_run_usage(String.t(), String.t(), map()) :: :ok | {:error, :not_found | term()}
  def record_run_usage(conversation_id, run_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_binary(run_id) and
             run_id != "" and is_map(usage) do
    normalized = normalize_usage(usage)

    with {:ok, _meta} <-
           transact_meta(conversation_id, fn existing ->
             runs = Map.get(existing, "run_usage", %{})
             Map.put(existing, "run_usage", Map.put_new(runs, run_id, normalized))
           end) do
      :ok
    end
  end

  @doc """
  Replace conversation totals with terminal `run_end` events the caller already
  loaded. Does not read `~/.handbeam/`. Interrupted events are ignored. The same
  `run_id` counts once; events without one are keyed by their position.
  """
  @spec rebuild_token_usage_from_events(String.t(), [map()]) ::
          :ok | {:error, :not_found | term()}
  def rebuild_token_usage_from_events(conversation_id, events)
      when is_binary(conversation_id) and conversation_id != "" and is_list(events) do
    runs =
      events
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {event, index}, acc ->
        if terminal_usage_event?(event) do
          Map.put(acc, event_run_key(event, index), normalize_usage(event_usage(event)))
        else
          acc
        end
      end)

    with {:ok, _meta} <-
           transact_meta(conversation_id, fn existing ->
             existing
             |> Map.put("run_usage_replace", true)
             |> Map.put("run_usage", runs)
             |> Map.put("usage_legacy", blank_usage())
           end) do
      :ok
    end
  end

  # ── Index helpers ───────────────────────────────────────────────────────

  @doc "Record each child run's raw usage once, separately from parent provider usage."
  def record_delegated_usage(conversation_id, child_run_id, usage) do
    with {:ok, meta} <- read_meta(conversation_id) do
      write_meta_file(conversation_id, Map.put(meta, "delegated_usage", %{child_run_id => usage}))
    end
  end

  @doc "Child usage keyed by child run id; never included in the parent's raw token_usage."
  def delegated_usage(conversation_id) do
    case read_meta(conversation_id) do
      {:ok, meta} -> Map.get(meta, "delegated_usage", %{})
      _ -> %{}
    end
  end

  defp read_index do
    storage_read(index_path())
    |> case do
      {:ok, content} when content == "" ->
        {:ok, %{"conversations" => []}}

      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, %{"conversations" => _} = data} -> {:ok, data}
          {:ok, _} -> {:error, :corrupted}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error(
          "[ConversationStore] Error reading index #{index_path()}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp write_index(data) do
    atomic_write_json(index_path(), data)
  end

  defp sync_index_entry(conversation) do
    with_index_lock(fn ->
      with {:ok, existing} <- index_entries_for_sync() do
        meta_entries = index_entries_from_items()
        entry = index_entry(conversation)

        updated =
          existing
          |> merge_index_entries(meta_entries)
          |> merge_index_entries([entry])
          |> sort_index_entries()

        write_index(%{"conversations" => updated})
      end
    end)
  end

  defp with_index_lock(fun) when is_function(fun, 0) do
    :global.trans({{__MODULE__, :index_lock, index_path()}, self()}, fun)
  end

  defp index_entries_for_sync do
    case read_index() do
      {:ok, data} ->
        {:ok, Map.get(data, "conversations", [])}

      {:error, :not_found} ->
        Logger.warning(fn ->
          "[ConversationStore] Index missing at #{index_path()}; rebuilding from items/*/meta.json"
        end)

        {:ok, []}

      {:error, :corrupted} ->
        Logger.error(
          "[ConversationStore] Index corrupted at #{index_path()}; rebuilding from items/*/meta.json"
        )

        {:ok, []}

      # Unreadable is not corrupt: a rebuild here could replace a good index
      # (for example while another VM holds the storage lock).
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp index_entries_from_items do
    storage_dir()
    |> Path.join("items/*/meta.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_index_meta_file(path) do
        {:ok, meta} -> [index_entry(meta)]
        {:error, _reason} -> []
      end
    end)
  end

  defp read_index_meta_file(path) do
    case storage_read(path) do
      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:ok, _} -> {:error, :corrupted}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_index_entries(entries, new_entries) do
    entries
    |> Enum.concat(new_entries)
    |> Enum.reduce(%{}, fn entry, acc ->
      case entry["id"] do
        id when is_binary(id) and id != "" -> Map.put(acc, id, entry)
        _ -> acc
      end
    end)
    |> Map.values()
  end

  defp sort_index_entries(entries) do
    Enum.sort_by(entries, &(&1["updated_at"] || ""), :desc)
  end

  defp index_entry(conversation) do
    %{
      "id" => conversation["id"],
      "visibility" => conversation["visibility"] || "user",
      "parent_conversation_id" => conversation["parent_conversation_id"],
      "parent_run_id" => conversation["parent_run_id"],
      "parent_tool_call_id" => conversation["parent_tool_call_id"],
      "scope" => conversation["scope"] || inferred_scope(conversation),
      "workspace_id" => conversation["workspace_id"],
      "title" => conversation["title"],
      "title_source" => conversation["title_source"],
      "archived_at" => conversation["archived_at"],
      "created_at" => conversation["created_at"],
      "updated_at" => conversation["updated_at"]
    }
  end

  defp inferred_scope(%{"scope" => "free"}), do: "free"
  defp inferred_scope(%{"workspace_id" => id}) when is_binary(id) and id != "", do: "workspace"
  defp inferred_scope(_), do: "workspace"

  defp normalize_scope(conversation) do
    case string_value(conversation, "scope") do
      "free" -> "free"
      "workspace" -> "workspace"
      _ -> inferred_scope(conversation)
    end
  end

  # ── Item file helpers ───────────────────────────────────────────────────

  defp read_item(id, opts) do
    with {:ok, meta} <- read_meta(id) do
      timeline = if Keyword.get(opts, :include_timeline?, true), do: load_messages(id), else: []
      files = load_files(id)

      conversation =
        Map.merge(meta, %{
          "timeline" => timeline,
          "editor_files" => Map.get(files, "editor_files", []),
          "active_file" => Map.get(files, "active_file"),
          "file_preview_error" => Map.get(files, "file_preview_error")
        })

      {:ok, conversation}
    end
  end

  defp write_item(conversation) do
    id = conversation["id"]
    ensure_conversation_dir(id)

    meta = extract_meta(conversation)
    timeline = list_value(conversation, "timeline")
    files = extract_files(conversation)

    with :ok <- write_meta_file(id, meta),
         :ok <- maybe_write_messages_file(id, timeline),
         :ok <- write_files_file(id, files) do
      :ok
    end
  end

  # ── Meta helpers ──────────────────────────────────────────────────────

  defp read_meta(id) do
    path = meta_path(id)

    case storage_read(path) do
      {:ok, content} when content == "" ->
        {:error, :not_found}

      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:ok, _} -> {:error, :corrupted}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[ConversationStore] Error reading meta #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write_meta_file(id, meta) do
    # Usage keys are owned by the locked usage writers. A stale full-meta write
    # must not replace them with a copy it read earlier.
    meta = Map.drop(meta, @usage_meta_keys)

    :global.trans({{__MODULE__, :meta, id}, self()}, fn ->
      # Only a missing or undecodable meta may be replaced from scratch; any
      # other read error means we cannot see keys we would otherwise drop.
      existing =
        case read_meta(id) do
          {:ok, data} -> {:ok, data}
          {:error, reason} when reason in [:not_found, :corrupted] -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end

      with {:ok, existing} <- existing do
        atomic_write_json(meta_path(id), finalize_meta(existing, Map.merge(existing, meta)))
      end
    end)
  end

  defp transact_meta(id, proposer) when is_function(proposer, 1) do
    :global.trans({{__MODULE__, :meta, id}, self()}, fn ->
      with {:ok, existing} <- read_meta(id) do
        finalized = finalize_meta(existing, proposer.(existing))

        case atomic_write_json(meta_path(id), finalized) do
          :ok -> {:ok, finalized}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp finalize_meta(existing, proposed) do
    delegated =
      Map.merge(
        Map.get(proposed, "delegated_usage", %{}),
        Map.get(existing, "delegated_usage", %{})
      )

    {run_usage, legacy} =
      if proposed["run_usage_replace"] == true do
        {Map.get(proposed, "run_usage") || %{}, normalize_usage(proposed["usage_legacy"] || %{})}
      else
        run_usage =
          Map.merge(
            Map.get(proposed, "run_usage", Map.get(existing, "run_usage", %{})),
            Map.get(existing, "run_usage", %{})
          )

        {run_usage, pick_legacy(existing, proposed, run_usage)}
      end

    proposed
    |> Map.delete("run_usage_replace")
    |> Map.put("delegated_usage", delegated)
    |> put_usage_fields(run_usage, legacy)
  end

  defp pick_legacy(existing, proposed, run_usage) do
    cond do
      is_map(proposed["usage_legacy"]) ->
        normalize_usage(proposed["usage_legacy"])

      is_map(existing["usage_legacy"]) ->
        normalize_usage(existing["usage_legacy"])

      run_usage != %{} and is_map(existing["token_usage"]) and not is_map(existing["run_usage"]) ->
        normalize_usage(existing["token_usage"])

      run_usage == %{} ->
        :unchanged

      true ->
        blank_usage()
    end
  end

  defp put_usage_fields(meta, _run_usage, :unchanged), do: meta

  defp put_usage_fields(meta, run_usage, legacy) do
    legacy = if is_map(legacy), do: legacy, else: blank_usage()

    meta
    |> Map.put("usage_legacy", legacy)
    |> Map.put("run_usage", run_usage)
    |> Map.put("token_usage", derive_token_usage(legacy, run_usage))
  end

  defp explicit_legacy(existing) do
    cond do
      is_map(existing["usage_legacy"]) ->
        normalize_usage(existing["usage_legacy"])

      is_map(existing["token_usage"]) and not is_map(existing["run_usage"]) ->
        normalize_usage(existing["token_usage"])

      true ->
        blank_usage()
    end
  end

  defp combined_usage(meta) do
    cond do
      is_map(meta["run_usage"]) or is_map(meta["usage_legacy"]) ->
        derive_token_usage(
          normalize_usage(meta["usage_legacy"] || %{}),
          if(is_map(meta["run_usage"]), do: meta["run_usage"], else: %{})
        )

      is_map(meta["token_usage"]) ->
        normalize_usage(meta["token_usage"])

      true ->
        blank_usage()
    end
  end

  defp derive_token_usage(legacy, run_usage) do
    Enum.reduce(Map.values(run_usage), legacy, fn usage, acc ->
      sum_stored(acc, normalize_usage(usage))
    end)
  end

  defp sum_stored(left, right) do
    %{
      "input_tokens" => left["input_tokens"] + right["input_tokens"],
      "output_tokens" => left["output_tokens"] + right["output_tokens"],
      "cache_read_tokens" => left["cache_read_tokens"] + right["cache_read_tokens"],
      "cache_write_tokens" => left["cache_write_tokens"] + right["cache_write_tokens"],
      "total_input_tokens" => left["total_input_tokens"] + right["total_input_tokens"],
      "unknown" => left["unknown"] or right["unknown"]
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    input = usage_number(usage, [:input_tokens, "input_tokens"])
    output = usage_number(usage, [:output_tokens, "output_tokens"])

    read =
      usage_number(usage, [
        :cache_read_input_tokens,
        "cache_read_input_tokens",
        :cache_read_tokens,
        "cache_read_tokens"
      ])

    write =
      usage_number(usage, [
        :cache_creation_input_tokens,
        "cache_creation_input_tokens",
        :cache_write_tokens,
        "cache_write_tokens"
      ])

    total =
      case usage_fetch(usage, [:total_input_tokens, "total_input_tokens"]) do
        number when is_number(number) -> round_usage(number)
        _ -> input + read + write
      end

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "cache_read_tokens" => read,
      "cache_write_tokens" => write,
      "total_input_tokens" => total,
      "unknown" => usage_unknown?(usage)
    }
  end

  defp normalize_usage(_), do: blank_usage()

  defp blank_usage do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0,
      "total_input_tokens" => 0,
      "unknown" => false
    }
  end

  defp usage_view(stored) do
    %{
      input_tokens: stored["input_tokens"],
      output_tokens: stored["output_tokens"],
      cache_read_tokens: stored["cache_read_tokens"],
      cache_write_tokens: stored["cache_write_tokens"],
      total_input_tokens: stored["total_input_tokens"],
      usage_incomplete: stored["unknown"] == true
    }
  end

  defp empty_token_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      total_input_tokens: 0,
      usage_incomplete: false
    }
  end

  defp usage_number(usage, keys) do
    case usage_fetch(usage, keys) do
      number when is_number(number) -> round_usage(number)
      _ -> 0
    end
  end

  defp usage_fetch(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(usage, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp usage_unknown?(usage) do
    usage_fetch(usage, [:unknown?, "unknown?", :unknown, "unknown"]) in [true, "true"]
  end

  defp round_usage(number) when is_integer(number), do: number
  defp round_usage(number) when is_float(number), do: round(number)

  defp terminal_usage_event?(event) when is_map(event) do
    kind = usage_fetch(event, [:kind, "kind"])
    status = event_status(event)
    kind in [:run_end, "run_end"] and status not in [:interrupted, "interrupted", nil]
  end

  defp terminal_usage_event?(_), do: false

  defp event_status(event) do
    payload = usage_fetch(event, [:payload, "payload"]) || %{}
    usage_fetch(payload, [:status, "status"])
  end

  defp event_usage(event) do
    payload = usage_fetch(event, [:payload, "payload"]) || %{}
    usage_fetch(payload, [:usage, "usage"]) || %{}
  end

  defp event_run_key(event, index) do
    payload = usage_fetch(event, [:payload, "payload"]) || %{}

    case usage_fetch(payload, [:run_id, "run_id"]) || usage_fetch(event, [:run_id, "run_id"]) do
      id when is_binary(id) and id != "" -> id
      _ -> "event-#{index}"
    end
  end

  defp extract_meta(conversation) do
    %{
      "id" => conversation["id"],
      "visibility" => conversation["visibility"] || "user",
      "parent_conversation_id" => conversation["parent_conversation_id"],
      "parent_run_id" => conversation["parent_run_id"],
      "parent_tool_call_id" => conversation["parent_tool_call_id"],
      "delegated_usage" => conversation["delegated_usage"] || %{},
      "scope" => conversation["scope"] || inferred_scope(conversation),
      "workspace_id" => conversation["workspace_id"],
      "title" => conversation["title"],
      "title_source" => conversation["title_source"],
      "archived_at" => conversation["archived_at"],
      "created_at" => conversation["created_at"],
      "updated_at" => conversation["updated_at"],
      "selected_model" => conversation["selected_model"],
      "selected_reasoning_level" => conversation["selected_reasoning_level"],
      "collaboration" => conversation["collaboration"],
      "last_run_result" => conversation["last_run_result"]
    }
  end

  # ── Messages file helpers ─────────────────────────────────────────────

  defp maybe_write_messages_file(id, []) do
    existing_messages = load_messages(id)

    if existing_messages == [] do
      write_messages_file(id, [])
    else
      dev_log(
        "[ConversationStore] preserving non-empty messages for #{id}; " <>
          "incoming timeline was empty"
      )

      :ok
    end
  end

  defp maybe_write_messages_file(id, timeline), do: write_messages_file(id, timeline)

  defp write_messages_file(id, timeline) when is_list(timeline) do
    Handbeam.ConversationTranscriptStore.Journal.replace(messages_path(id), timeline)
  end

  # ── Files helpers ─────────────────────────────────────────────────────

  defp write_files_file(id, files_data) do
    atomic_write_json(files_path(id), files_data)
  end

  defp extract_files(conversation) do
    %{
      "editor_files" => list_value(conversation, "editor_files"),
      "active_file" => value(conversation, "active_file"),
      "file_preview_error" => value(conversation, "file_preview_error")
    }
  end

  # ── Directory helpers ─────────────────────────────────────────────────

  defp ensure_conversation_dir(id) do
    conversation_dir(id) |> File.mkdir_p!()
  end

  # ── Atomic write (tmp + rename) ─────────────────────────────────────────

  defp atomic_write_json(path, data) do
    case Handbeam.ConversationTranscriptStore.Journal.write_json(storage_dir(), path, data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[ConversationStore] Error writing #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp storage_read(path) do
    Handbeam.ConversationTranscriptStore.Journal.read_file(storage_dir(), path)
  end

  # ── Normalization ───────────────────────────────────────────────────────

  defp load_from_index_entry(entry, opts) do
    id = entry["id"]

    case read_item(id, opts) do
      {:ok, conversation} ->
        conversation

      {:error, :not_found} ->
        # Item directory missing: use index metadata as fallback
        Map.merge(entry, %{
          "timeline" => [],
          "editor_files" => [],
          "active_file" => nil,
          "file_preview_error" => nil
        })

      {:error, reason} ->
        Logger.warning(fn ->
          "[ConversationStore] Skipping unreadable item #{id}: #{inspect(reason)}"
        end)

        nil
    end
  end

  defp normalize_conversation(conversation) do
    now = now_iso8601()

    %{
      "id" => string_value(conversation, "id") || Ecto.UUID.generate(),
      "visibility" => string_value(conversation, "visibility") || "user",
      "parent_conversation_id" => string_value(conversation, "parent_conversation_id"),
      "parent_run_id" => string_value(conversation, "parent_run_id"),
      "parent_tool_call_id" => string_value(conversation, "parent_tool_call_id"),
      "delegated_usage" => value(conversation, "delegated_usage") || %{},
      "scope" => normalize_scope(conversation),
      "workspace_id" => string_value(conversation, "workspace_id"),
      "title" => string_value(conversation, "title") || "New chat",
      "title_source" => string_value(conversation, "title_source") || "manual",
      "timeline" => list_value(conversation, "timeline"),
      "editor_files" => list_value(conversation, "editor_files"),
      "active_file" => value(conversation, "active_file"),
      "file_preview_error" => value(conversation, "file_preview_error"),
      "selected_model" => string_value(conversation, "selected_model"),
      "selected_reasoning_level" => string_value(conversation, "selected_reasoning_level"),
      "collaboration" => value(conversation, "collaboration"),
      "last_run_result" => value(conversation, "last_run_result"),
      "archived_at" => string_value(conversation, "archived_at"),
      "created_at" => string_value(conversation, "created_at") || now,
      "updated_at" => now
    }
  end

  # ── Filters ─────────────────────────────────────────────────────────────

  defp maybe_filter_archived(conversations, true), do: conversations

  defp maybe_filter_archived(conversations, false) do
    Enum.reject(conversations, fn c ->
      case Map.get(c, "archived_at") do
        v when is_binary(v) and v != "" -> true
        _ -> false
      end
    end)
  end

  # ── Value helpers ───────────────────────────────────────────────────────

  defp value(map, key) do
    Handbeam.Utils.SafeMap.get(map, key)
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) -> value
      nil -> nil
      value -> to_string(value)
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  # ── Time ────────────────────────────────────────────────────────────────

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
