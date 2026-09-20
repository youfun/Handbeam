defmodule HandbeamWeb.WorkspaceLive.ConversationState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

  require Logger

  alias HandbeamWeb.WorkspaceLive.ConversationSwitching

  def sync_conv_state(socket, opts \\ []) do
    conv =
      if Keyword.get(opts, :reload?, false) do
        load_current_conversation_from_store(socket) || current_conv_map(socket)
      else
        current_conv_map(socket)
      end

    socket
    |> maybe_replace_current_conversation(conv)
    |> sync_conv_from(conv, opts)
  end

  def sync_conv_from(socket, conv, opts \\ []) do
    current_timeline = Map.get(socket.assigns, :timeline, [])

    fallback =
      if current_timeline != [],
        do: current_timeline,
        else: conv_value(conv, "timeline", [])

    conv_id = conversation_id(conv)

    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    {timeline, history_before, history_has_more?} =
      if running_for_conversation?(socket, conv_id) and current_timeline != [] do
        {current_timeline, Map.get(socket.assigns, :history_before),
         Map.get(socket.assigns, :history_has_more?, false)}
      else
        conv_id
        |> load_transcript_page(fallback)
        |> then(fn {entries, before, has_more?} ->
          {HandbeamWeb.WorkspaceHelper.apply_tool_work_collapse(entries, expanded), before,
           has_more?}
        end)
      end

    available_models = Map.get(socket.assigns, :available_models, [])
    selected_model = conversation_selected_model(socket, conv, available_models)
    token_usage = load_conversation_token_usage(conv_id)
    running_for_conversation? = running_for_conversation?(socket, conv_id)

    socket =
      socket
      |> assign(:timeline, timeline)
      |> assign(:history_before, history_before)
      |> assign(:history_has_more?, history_has_more?)
      |> maybe_reset_timeline_stream(timeline, running_for_conversation?)

    socket
    |> assign(
      :editor_files,
      conv_value(conv, "editor_files", []) |> Enum.map(&normalize_editor_file/1)
    )
    |> assign(:active_file, conv_value(conv, "active_file", nil))
    |> assign(:file_preview_error, conv_value(conv, "file_preview_error", nil))
    |> assign(:selected_model, selected_model)
    |> sync_reasoning_for_conversation(conv, selected_model, opts)
    |> maybe_update_status(
      Map.merge(
        %{model: model_display_name(selected_model, available_models, opts)},
        token_usage
      ),
      opts
    )
    |> assign(:show_diff, false)
    |> assign(:diff_lines, nil)
    |> assign(:active_change, nil)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
    |> load_effective_settings(opts)
  end

  def sync_conv_to(socket) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = socket.assigns.current_workspace_id
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      Enum.map(current_convs, fn c ->
        if conversation_id(c) == conv_id do
          merge_conversation_state(c, socket)
        else
          c
        end
      end)

    socket =
      socket
      |> assign(:conversations_by_workspace, Map.put(convs, ws_id, updated))

    persist_current_conversation(socket)
    socket
  end

  def update_conv(socket, conv) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = socket.assigns.current_workspace_id
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      Enum.map(current_convs, fn c ->
        if conversation_id(c) == conv_id, do: conv, else: c
      end)

    socket =
      socket
      |> assign(:conversations_by_workspace, Map.put(convs, ws_id, updated))
      |> ConversationSwitching.reload_conversation_stream()

    persist_current_conversation(socket)
    socket
  end

  def select_file(socket, path, workspace_root, opts \\ []) do
    conv = current_conv_map(socket)

    socket =
      case validate_within(path, workspace_root) do
        :ok ->
          abs_path = Path.expand(path)

          conv
          |> put_conversation_value("active_file", abs_path)
          |> put_conversation_value(
            "file_preview_error",
            load_file_error(abs_path, workspace_root)
          )
          |> then(&update_conv(socket, &1))

        {:error, reason} ->
          conv
          |> put_conversation_value("active_file", nil)
          |> put_conversation_value("file_preview_error", reason)
          |> then(&update_conv(socket, &1))
      end

    sync_conv_state(socket, opts)
  end

  def current_conv_map(socket) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = socket.assigns.current_workspace_id
    convs = Map.get(socket.assigns.conversations_by_workspace, ws_id, [])

    Enum.find(convs, &(conversation_id(&1) == conv_id)) ||
      load_or_build_current_conversation(conv_id, ws_id)
  end

  def load_current_conversation_from_store(socket) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) do
      case Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
        {:ok, conversation} ->
          Logger.debug(
            "[WorkspaceLive] loaded conversation from store conversation=#{conv_id} " <>
              "metadata_only=true"
          )

          conversation

        {:error, :not_found} ->
          nil
      end
    end
  end

  def load_transcript_entries(conversation_id, fallback) when is_binary(conversation_id) do
    case Handbeam.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} -> entries
      {:error, _reason} -> fallback
    end
  end

  def load_transcript_entries(_conversation_id, fallback), do: fallback

  def load_transcript_page(conversation_id, fallback) when is_binary(conversation_id) do
    case Handbeam.ConversationTranscriptStore.page(conversation_id, limit: 100) do
      {:ok, %{entries: entries, before: before, has_more?: has_more?}} ->
        {entries, before, has_more?}

      {:error, _reason} ->
        {fallback, nil, false}
    end
  end

  def load_transcript_page(_conversation_id, fallback), do: {fallback, nil, false}

  def load_older_history(socket) do
    conv_id = socket.assigns.current_conversation_id
    before = Map.get(socket.assigns, :history_before)

    with true <- is_binary(conv_id) and is_binary(before),
         {:ok, %{entries: entries, before: next_before, has_more?: has_more?}} <-
           Handbeam.ConversationTranscriptStore.page(conv_id, limit: 100, before: before) do
      timeline = deduplicate_entries(entries ++ socket.assigns.timeline)

      socket
      |> assign(:timeline, timeline)
      |> assign(:history_before, next_before)
      |> assign(:history_has_more?, has_more?)
      |> stream(:timeline, timeline, reset: true)
    else
      _ -> socket
    end
  end

  def maybe_replace_current_conversation(socket, conv) do
    if is_binary(socket.assigns.current_conversation_id) do
      replace_current_conversation(socket, conv)
    else
      socket
    end
  end

  def replace_current_conversation(socket, conv) do
    conv_id = conversation_id(conv)
    ws_id = conv_value(conv, "workspace_id", socket.assigns.current_workspace_id)
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      if Enum.any?(current_convs, &(conversation_id(&1) == conv_id)) do
        Enum.map(current_convs, fn existing ->
          if conversation_id(existing) == conv_id, do: conv, else: existing
        end)
      else
        current_convs ++ [conv]
      end

    assign(socket, :conversations_by_workspace, Map.put(convs, ws_id, updated))
  end

  def merge_conversation_state(conversation, socket) do
    conversation
    |> put_conversation_value("editor_files", socket.assigns.editor_files)
    |> put_conversation_value("active_file", socket.assigns.active_file)
    |> put_conversation_value("file_preview_error", socket.assigns.file_preview_error)
    |> put_conversation_value("selected_model", socket.assigns.selected_model)
    |> put_conversation_value("selected_reasoning_level", socket.assigns.selected_reasoning_level)
  end

  def put_conversation_value(conversation, key, value) do
    if Map.has_key?(conversation, key) do
      Map.put(conversation, key, value)
    else
      try do
        Map.put(conversation, String.to_existing_atom(key), value)
      rescue
        ArgumentError -> conversation
      end
    end
  end

  def conv_value(conversation, key, default) do
    try do
      Map.get(conversation, key, Map.get(conversation, String.to_existing_atom(key), default))
    rescue
      ArgumentError -> default
    end
  end

  def conversation_id(conversation), do: conv_value(conversation, "id", nil)

  def build_memory_conversation(workspace_id, num) do
    now = DateTime.utc_now()

    %{
      "id" => Ecto.UUID.generate(),
      "workspace_id" => workspace_id,
      "title" => conversation_title(num),
      "title_source" => "manual",
      "timeline" => [],
      "editor_files" => [],
      "active_file" => nil,
      "file_preview_error" => nil,
      "created_at" => now,
      "updated_at" => now
    }
  end

  def persist_current_conversation(socket) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) do
      _ =
        Handbeam.ConversationStore.save_files(conv_id, %{
          "editor_files" => socket.assigns.editor_files,
          "active_file" => socket.assigns.active_file,
          "file_preview_error" => socket.assigns.file_preview_error
        })

      _ =
        Handbeam.ConversationStore.update_meta(conv_id,
          selected_model: socket.assigns.selected_model,
          selected_reasoning_level: socket.assigns.selected_reasoning_level
        )

      :ok
    else
      :ok
    end
  end

  def load_conversation_token_usage(conv_id) do
    case Handbeam.ConversationStore.get_token_usage(conv_id) do
      {:ok, tokens} ->
        tokens

      {:error, _} ->
        %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0}
    end
  rescue
    _ -> %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0}
  end

  def running_for_current_conversation?(socket) do
    running_for_conversation?(socket, Map.get(socket.assigns, :current_conversation_id))
  end

  defp maybe_reset_timeline_stream(socket, _timeline, true), do: socket

  defp maybe_reset_timeline_stream(socket, timeline, false) do
    socket
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:stream_suppressed, false)
    |> assign(:thinking_active, false)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> maybe_assign_idle_status()
    |> stream(:timeline, timeline, reset: true)
  end

  defp running_for_conversation?(socket, conv_id) when is_binary(conv_id) do
    Map.get(socket.assigns, :running, false) and
      Map.get(socket.assigns, :running_conversation_id) == conv_id
  end

  defp running_for_conversation?(_socket, _conv_id), do: false

  defp maybe_assign_idle_status(socket) do
    if Map.has_key?(socket.assigns, :status_info) do
      assign(socket, :status_info, Map.merge(socket.assigns.status_info, %{status: :idle}))
    else
      socket
    end
  end

  defp load_or_build_current_conversation(conv_id, ws_id)
       when is_binary(conv_id) and is_binary(ws_id) do
    case Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, conversation} ->
        conversation

      {:error, :not_found} ->
        build_memory_conversation(ws_id, 1)
    end
  end

  defp load_or_build_current_conversation(_conv_id, ws_id),
    do: build_memory_conversation(ws_id, 1)

  defp validate_within(path, workspace_root) do
    Handbeam.Security.PathValidator.validate_within_workspace(Path.expand(path), workspace_root)
  end

  defp load_file_error(nil, _workspace_root), do: nil

  defp load_file_error(path, workspace_root) do
    case Handbeam.Workspace.resolve(path, workspace_root) do
      {:ok, _} ->
        case File.read(path) do
          {:ok, _} -> nil
          {:error, reason} -> reason
        end

      {:error, reason} ->
        reason
    end
  end

  defp normalize_editor_file(%{path: _, name: _} = file), do: file
  defp normalize_editor_file(%{"path" => path, "name" => name}), do: %{path: path, name: name}
  defp normalize_editor_file(file), do: file

  defp deduplicate_entries(entries) do
    Enum.uniq_by(entries, &conv_value(&1, "id", nil))
  end

  defp conversation_selected_model(_socket, conv, available) do
    stored_model = conv_value(conv, "selected_model", nil)

    cond do
      stored_model && Enum.any?(available, &(&1.id == stored_model)) ->
        stored_model

      match?([_ | _], available) ->
        first = List.first(available)
        first && first.id

      true ->
        nil
    end
  end

  defp sync_reasoning_for_conversation(socket, conv, selected_model, opts) do
    case Keyword.get(opts, :sync_reasoning_for_conversation) do
      fun when is_function(fun, 3) -> fun.(socket, conv, selected_model)
      _ -> socket
    end
  end

  defp model_display_name(selected_model, available_models, opts) do
    case Keyword.get(opts, :model_display_name) do
      fun when is_function(fun, 2) -> fun.(selected_model, available_models)
      _ -> selected_model || "None"
    end
  end

  defp maybe_update_status(socket, overrides, opts) do
    case Keyword.get(opts, :update_status) do
      fun when is_function(fun, 2) ->
        fun.(socket, overrides)

      _ ->
        if Map.has_key?(socket.assigns, :status_info) do
          assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))
        else
          socket
        end
    end
  end

  defp load_effective_settings(socket, opts) do
    case Keyword.get(opts, :load_effective_settings) do
      fun when is_function(fun, 1) -> fun.(socket)
      _ -> socket
    end
  end

  defp conversation_title(1), do: "New chat"
  defp conversation_title(num), do: "New chat ##{num}"
end
