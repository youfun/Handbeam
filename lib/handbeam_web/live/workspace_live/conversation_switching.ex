defmodule HandbeamWeb.WorkspaceLive.ConversationSwitching do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream: 4]

  require Logger

  alias HandbeamWeb.WorkspaceLive.ConversationState

  @free_key :free

  def assign_current(socket, ws, conversation_id) do
    socket
    |> assign(:chat_scope, :workspace)
    |> assign(:current_workspace_id, ws["id"])
    |> assign(:current_conversation_id, conversation_id)
    |> assign(:conversation_menu_id, nil)
    |> assign(:rename_conversation, nil)
    |> assign(:workspace_root, ws["path"])
    |> assign(:workspace_label, ws["name"])
    |> assign(:expanded_tool_groups, MapSet.new())
    |> assign(:pending_messages, %{})
    |> assign(:history_before, nil)
    |> assign(:history_has_more?, false)
  end

  def select_workspace(socket, ws_id) do
    {:ok, ws} = Handbeam.WorkspaceStore.get(ws_id)
    Handbeam.WorkspaceStore.touch(ws_id)

    {socket, conv} = ensure_active_conversation(socket, ws_id)
    socket = assign_current(socket, ws, ConversationState.conversation_id(conv))
    {socket, ConversationState.conversation_id(conv)}
  end

  def select_conversation(socket, ws_id, conv_id) do
    {:ok, ws} = Handbeam.WorkspaceStore.get(ws_id)
    Handbeam.WorkspaceStore.touch(ws_id)

    {assign_current(socket, ws, conv_id), conv_id}
  end

  def select_archived_conversation(socket, ws_id, conv_id) do
    {:ok, ws} = Handbeam.WorkspaceStore.get(ws_id)
    {assign_current(socket, ws, conv_id), conv_id}
  end

  def select_new_workspace_without_conversation(socket, new_ws, workspaces) do
    conversations_by_ws =
      workspaces
      |> build_conversations_by_workspace(include_archived?: true)
      |> Map.put_new(new_ws["id"], [])

    socket
    |> assign(:workspaces, workspaces)
    |> assign(:conversations_by_workspace, conversations_by_ws)
    |> reload_conversation_stream()
    |> assign_current(new_ws, nil)
  end

  def ensure_current_conversation(socket, opts \\ []) do
    if current_conversation_present?(socket) do
      socket
    else
      if socket.assigns[:chat_scope] == :free do
        ensure_current_free_conversation(socket, opts)
      else
        ensure_current_workspace_conversation(socket, opts)
      end
    end
  end

  defp ensure_current_free_conversation(socket, opts) do
    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        load_free_conversations(include_archived?: true)
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])

    {socket, conv} =
      case Enum.find(conversations, &(not archived_conversation?(&1))) do
        nil ->
          conversation = build_free_conversation(length(conversations) + 1)

          socket =
            update(socket, :conversations_by_workspace, fn conversations_by_workspace ->
              Map.put(conversations_by_workspace, @free_key, conversations ++ [conversation])
            end)

          {socket, conversation}

        conversation ->
          {socket, conversation}
      end

    socket
    |> assign_free(ConversationState.conversation_id(conv))
    |> reload_conversation_stream()
    |> ConversationState.sync_conv_state(opts)
  end

  defp ensure_current_workspace_conversation(socket, opts) do
    ws_id = socket.assigns.current_workspace_id

    conversations_by_ws =
      build_conversations_by_workspace(socket.assigns.workspaces, include_archived?: true)

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    {socket, conv} = ensure_active_conversation(socket, ws_id)

    socket
    |> assign(:current_conversation_id, ConversationState.conversation_id(conv))
    |> reload_conversation_stream()
    |> ConversationState.sync_conv_state(opts)
  end

  def archive_conversation(socket, conv_id, ws_id, opts \\ []) do
    _ = Handbeam.ConversationStore.archive(conv_id)

    conversations_by_ws =
      build_conversations_by_workspace(socket.assigns.workspaces, include_archived?: true)

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()

    if socket.assigns.current_conversation_id == conv_id do
      {socket, next} = ensure_active_conversation(socket, ws_id)
      next_id = ConversationState.conversation_id(next)

      socket =
        socket
        |> assign(:current_conversation_id, next_id)
        |> reload_conversation_stream()
        |> ConversationState.sync_conv_state(opts)
        |> ConversationState.sync_conv_to()

      {socket, next_id}
    else
      {socket, nil}
    end
  end

  def unarchive_conversation(socket, conv_id) do
    _ = Handbeam.ConversationStore.unarchive(conv_id)

    conversations_by_ws =
      build_conversations_by_workspace(socket.assigns.workspaces, include_archived?: true)

    socket
    |> assign(:conversations_by_workspace, conversations_by_ws)
    |> reload_conversation_stream()
  end

  def remove_workspace(socket, ws_id) do
    with {:ok, removed} <- Handbeam.WorkspaceStore.remove(ws_id),
         {:ok, _archived} <- Handbeam.ConversationStore.archive_for_workspace(ws_id) do
      workspaces = Handbeam.WorkspaceStore.list()

      conversations_by_ws =
        workspaces
        |> build_conversations_by_workspace(include_archived?: true)
        |> Map.put(@free_key, load_free_conversations(include_archived?: true))
        |> Map.put(ws_id, orphaned_archived_conversations(ws_id))

      socket =
        socket
        |> assign(:workspaces, workspaces)
        |> assign(:conversations_by_workspace, conversations_by_ws)
        |> assign(:workspace_menu_id, nil)
        |> assign(:remove_workspace, nil)
        |> assign(:show_archive, true)
        |> reload_conversation_stream()

      {:ok, socket, removed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp orphaned_archived_conversations(ws_id) do
    Handbeam.ConversationStore.list_for_workspace(ws_id,
      include_archived?: true,
      include_timeline?: false
    )
    |> Enum.filter(&archived_conversation?/1)
  end

  def free_key, do: @free_key

  def load_free_conversations(opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    Handbeam.ConversationStore.list_free(
      include_archived?: include_archived?,
      include_timeline?: false
    )
    |> Enum.reject(fn conv ->
      String.starts_with?(ConversationState.conv_value(conv, "title", ""), "New chat") and
        ConversationState.conv_value(conv, "title_source", nil) in [nil, "manual"] and
        transcript_empty?(ConversationState.conversation_id(conv))
    end)
  end

  def new_free_conversation(socket, opts \\ []) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, @free_key, [])
    conversation = build_free_conversation(length(conversations) + 1)

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        @free_key,
        conversations ++ [conversation]
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()
      |> assign_free(ConversationState.conversation_id(conversation))
      |> then(Keyword.get(opts, :initialize_model, &Function.identity/1))
      |> reset_new_conversation_projection(opts)
      |> ConversationState.sync_conv_to()

    {socket, ConversationState.conversation_id(conversation)}
  end

  def select_free_conversation(socket, conv_id) do
    {assign_free(socket, conv_id), conv_id}
  end

  def assign_free(socket, conversation_id) do
    socket
    |> assign(:chat_scope, :free)
    |> assign(:current_workspace_id, nil)
    |> assign(:current_conversation_id, conversation_id)
    |> assign(:conversation_menu_id, nil)
    |> assign(:rename_conversation, nil)
    |> assign(:workspace_root, nil)
    |> assign(:workspace_label, "Chats")
    |> assign(:expanded_tool_groups, MapSet.new())
    |> assign(:pending_messages, %{})
    |> assign(:history_before, nil)
    |> assign(:history_has_more?, false)
  end

  def new_conversation(socket, workspace_id, opts \\ []) do
    {:ok, ws} = Handbeam.WorkspaceStore.get(workspace_id)
    Handbeam.WorkspaceStore.touch(workspace_id)

    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])
    conversation = build_conversation(workspace_id, length(conversations) + 1)

    conversations_by_ws =
      Map.put(
        socket.assigns.conversations_by_workspace,
        workspace_id,
        conversations ++ [conversation]
      )

    socket =
      socket
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> reload_conversation_stream()
      |> assign_current(ws, ConversationState.conversation_id(conversation))
      |> then(Keyword.get(opts, :initialize_model, &Function.identity/1))
      |> reset_new_conversation_projection(opts)
      |> ConversationState.sync_conv_to()

    {socket, ConversationState.conversation_id(conversation)}
  end

  def refresh_conversation_in_sidebar(socket, conv_id) do
    case Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, updated_conv} ->
        ws_id =
          if Handbeam.ConversationStore.free?(updated_conv),
            do: @free_key,
            else: ConversationState.conv_value(updated_conv, "workspace_id", nil)

        convs = socket.assigns.conversations_by_workspace
        bucket = sidebar_bucket(convs, conv_id) || ws_id
        current_convs = Map.get(convs, bucket, [])

        updated_convs =
          if Enum.any?(current_convs, &(ConversationState.conversation_id(&1) == conv_id)) do
            Enum.map(current_convs, fn existing ->
              if ConversationState.conversation_id(existing) == conv_id do
                merge_refreshed_title(existing, updated_conv)
              else
                existing
              end
            end)
          else
            current_convs ++ [updated_conv]
          end

        socket
        |> assign(:conversations_by_workspace, Map.put(convs, bucket, updated_convs))
        |> reload_conversation_stream()

      {:error, :not_found} ->
        socket
    end
  end

  def apply_sidebar_title(socket, conv_id, title, source \\ "auto")
      when is_binary(conv_id) and is_binary(title) and is_binary(source) do
    convs = socket.assigns.conversations_by_workspace

    updated =
      Map.new(convs, fn {bucket, list} ->
        {bucket,
         Enum.map(list, fn conv ->
           if ConversationState.conversation_id(conv) == conv_id do
             conv
             |> ConversationState.put_conversation_value("title", title)
             |> ConversationState.put_conversation_value("title_source", source)
           else
             conv
           end
         end)}
      end)

    socket
    |> assign(:conversations_by_workspace, updated)
    |> reload_conversation_stream()
  end

  defp sidebar_bucket(convs, conv_id) do
    Enum.find_value(convs, fn {bucket, list} ->
      if Enum.any?(list, &(ConversationState.conversation_id(&1) == conv_id)), do: bucket
    end)
  end

  # A store read can still show "New chat" if it races the title write. Do not
  # replace a title the sidebar already received.
  defp merge_refreshed_title(existing, updated) do
    existing_title = ConversationState.conv_value(existing, "title", "")
    updated_title = ConversationState.conv_value(updated, "title", "")

    if String.starts_with?(to_string(updated_title), "New chat") and
         not String.starts_with?(to_string(existing_title), "New chat") do
      updated
      |> ConversationState.put_conversation_value("title", existing_title)
      |> ConversationState.put_conversation_value(
        "title_source",
        ConversationState.conv_value(existing, "title_source", "auto")
      )
    else
      updated
    end
  end

  def build_initial_conversations(workspaces, _default_ws) do
    workspaces
    |> build_conversations_by_workspace(include_archived?: true)
    |> Map.put(@free_key, load_free_conversations(include_archived?: true))
  end

  def initial_conversation_id(conversations_by_ws, ws_id) do
    conversations_by_ws
    |> Map.get(ws_id, [])
    |> first_active_conversation()
    |> case do
      nil -> nil
      conversation -> ConversationState.conversation_id(conversation)
    end
  end

  def build_conversation(workspace_id, num) do
    title = conversation_title(num)
    {:ok, conversation} = Handbeam.ConversationStore.create(workspace_id, [{"title", title}])
    conversation
  end

  def build_free_conversation(num) do
    title = conversation_title(num)
    {:ok, conversation} = Handbeam.ConversationStore.create_free(title: title)
    conversation
  end

  def build_conversations_by_workspace(workspaces, opts) do
    include_archived? = Keyword.get(opts, :include_archived?, false)

    workspaces
    |> Enum.map(fn ws ->
      ws_id = ws["id"]

      convs =
        Handbeam.ConversationStore.list_for_workspace(ws_id,
          include_archived?: include_archived?,
          include_timeline?: false
        )
        |> Enum.reject(fn conv ->
          String.starts_with?(ConversationState.conv_value(conv, "title", ""), "New chat") and
            ConversationState.conv_value(conv, "title_source", nil) in [nil, "manual"] and
            transcript_empty?(ConversationState.conversation_id(conv))
        end)

      dev_log(
        "[WorkspaceLive] loaded conversations workspace_id=#{inspect(ws_id)} " <>
          "workspace_path=#{inspect(ws["path"])} include_archived?=#{include_archived?} " <>
          "count=#{length(convs)} ids=#{inspect(Enum.map(convs, &ConversationState.conversation_id/1))}"
      )

      {ws_id, maybe_sort_conversations(convs, include_archived?)}
    end)
    |> Map.new()
  end

  def ensure_active_conversation(socket, workspace_id) do
    conversations = Map.get(socket.assigns.conversations_by_workspace, workspace_id, [])

    case first_active_conversation(conversations) do
      nil ->
        conversation = build_conversation(workspace_id, length(conversations) + 1)

        socket =
          update(socket, :conversations_by_workspace, fn conversations_by_workspace ->
            Map.put(conversations_by_workspace, workspace_id, conversations ++ [conversation])
          end)

        {socket, conversation}

      conversation ->
        {socket, conversation}
    end
  end

  def stream_conversations(socket, conversations_by_ws, workspaces) do
    ws_names = Map.new(workspaces, fn ws -> {ws["id"], ws["name"]} end)

    items =
      conversations_by_ws
      |> Enum.flat_map(fn {ws_id, convs} ->
        Enum.map(convs, fn conv ->
          %{
            id: ConversationState.conversation_id(conv),
            title: ConversationState.conv_value(conv, "title", "New chat"),
            workspace_id: stream_workspace_id(ws_id),
            workspace_name: stream_workspace_name(ws_id, ws_names),
            scope: if(ws_id == @free_key, do: "free", else: "workspace"),
            archived: archived_conversation?(conv)
          }
        end)
      end)
      |> Enum.sort_by(&{&1.archived, &1.title})

    stream(socket, :conversations, items, reset: true)
  end

  def reload_conversation_stream(socket) do
    stream_conversations(
      socket,
      socket.assigns.conversations_by_workspace,
      socket.assigns.workspaces
    )
  end

  def archived_conversations(workspaces, conversations_by_workspace)
      when is_list(workspaces) and is_map(conversations_by_workspace) do
    ws_map =
      Map.new(workspaces, fn ws ->
        {ws["id"], ws["name"] || ws["id"]}
      end)

    conversations_by_workspace
    |> Enum.flat_map(fn {ws_id, convs} ->
      label = Map.get(ws_map, ws_id, ws_id)

      convs
      |> Enum.filter(&archived_conversation?/1)
      |> Enum.map(fn c ->
        %{
          id: ConversationState.conversation_id(c),
          title: ConversationState.conv_value(c, "title", "Archived"),
          workspace_id: ws_id,
          workspace_label: label,
          updated_at: ConversationState.conv_value(c, "updated_at", "")
        }
      end)
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  def free_conversations(conversations_by_workspace) when is_map(conversations_by_workspace) do
    conversations_by_workspace
    |> Map.get(@free_key, [])
    |> Enum.reject(&archived_conversation?/1)
    |> Enum.map(&conversation_row(&1, nil, "对话", "free"))
  end

  def workspace_conversations(conversations_by_workspace, ws_id, workspaces)
      when is_map(conversations_by_workspace) and is_list(workspaces) do
    ws_map = Map.new(workspaces, fn ws -> {ws["id"], ws["name"] || ws["id"]} end)

    conversations_by_workspace
    |> Map.get(ws_id, [])
    |> Enum.reject(&archived_conversation?/1)
    |> Enum.map(fn conv ->
      conversation_row(conv, ws_id, Map.get(ws_map, ws_id, ws_id), "workspace")
    end)
  end

  defp conversation_row(conv, workspace_id, workspace_name, scope) do
    %{
      id: ConversationState.conversation_id(conv),
      title: ConversationState.conv_value(conv, "title", "New chat"),
      workspace_id: workspace_id,
      workspace_name: workspace_name,
      scope: scope,
      archived: archived_conversation?(conv),
      updated_at: ConversationState.conv_value(conv, "updated_at", nil),
      created_at: ConversationState.conv_value(conv, "created_at", nil)
    }
  end

  defp stream_workspace_id(@free_key), do: nil
  defp stream_workspace_id(ws_id), do: ws_id

  defp stream_workspace_name(@free_key, _ws_names), do: "对话"
  defp stream_workspace_name(ws_id, ws_names), do: Map.get(ws_names, ws_id, ws_id)

  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_conversation?(conversation) do
    Handbeam.ConversationStore.archived_conversation?(conversation)
  end

  defp reset_new_conversation_projection(socket, opts) do
    socket
    |> assign(:input_value, "")
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:tools_active, %{})
    |> assign(:editor_files, [])
    |> assign(:active_file, nil)
    |> assign(:file_preview_error, nil)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
    |> assign(:timeline, [])
    |> assign(:expanded_tool_groups, MapSet.new())
    |> stream(:timeline, [], reset: true)
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> update_status_for_new_conversation(opts)
  end

  defp update_status_for_new_conversation(socket, opts) do
    available_models = Map.get(socket.assigns, :available_models, [])
    selected_model = Map.get(socket.assigns, :selected_model)
    display_name = model_display_name(selected_model, available_models, opts)

    overrides = %{
      model: display_name,
      status: :idle,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      turns: 0
    }

    case Keyword.get(opts, :update_status) do
      fun when is_function(fun, 2) -> fun.(socket, overrides)
      _ -> assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))
    end
  end

  defp model_display_name(selected_model, available_models, opts) do
    case Keyword.get(opts, :model_display_name) do
      fun when is_function(fun, 2) -> fun.(selected_model, available_models)
      _ -> selected_model || "None"
    end
  end

  defp current_conversation_present?(socket) do
    conv_id = socket.assigns.current_conversation_id

    bucket =
      if socket.assigns[:chat_scope] == :free,
        do: @free_key,
        else: socket.assigns.current_workspace_id

    convs = Map.get(socket.assigns.conversations_by_workspace, bucket, [])

    is_binary(conv_id) and
      Enum.any?(convs, &(ConversationState.conversation_id(&1) == conv_id))
  end

  defp first_active_conversation(conversations) do
    Enum.find(conversations, &(not archived_conversation?(&1)))
  end

  defp transcript_empty?(conversation_id) do
    case Handbeam.ConversationTranscriptStore.page(conversation_id, limit: 1) do
      {:ok, %{entries: []}} -> true
      _ -> false
    end
  end

  defp maybe_sort_conversations(conversations, true) do
    Enum.sort_by(
      conversations,
      fn c -> {not is_binary(c["archived_at"]), c["updated_at"] || ""} end,
      :desc
    )
  end

  defp maybe_sort_conversations(conversations, false), do: conversations

  defp conversation_title(1), do: "New chat"
  defp conversation_title(num), do: "New chat ##{num}"

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end
end
