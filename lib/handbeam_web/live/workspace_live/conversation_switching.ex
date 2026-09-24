defmodule HandbeamWeb.WorkspaceLive.ConversationSwitching do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream: 4]

  require Logger

  alias HandbeamWeb.WorkspaceLive.ConversationState

  def assign_current(socket, ws, conversation_id) do
    socket
    |> assign(:current_workspace_id, ws["id"])
    |> assign(:current_conversation_id, conversation_id)
    |> assign(:conversation_menu_id, nil)
    |> assign(:rename_conversation, nil)
    |> assign(:thread_collaboration_enabled, HandbeamWeb.ThreadHandoff.enabled?(conversation_id))
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
        ws_id = ConversationState.conv_value(updated_conv, "workspace_id", nil)
        convs = socket.assigns.conversations_by_workspace
        current_convs = Map.get(convs, ws_id, [])

        updated_convs =
          if Enum.any?(current_convs, &(ConversationState.conversation_id(&1) == conv_id)) do
            Enum.map(current_convs, fn c ->
              if ConversationState.conversation_id(c) == conv_id, do: updated_conv, else: c
            end)
          else
            current_convs ++ [updated_conv]
          end

        socket
        |> assign(:conversations_by_workspace, Map.put(convs, ws_id, updated_convs))
        |> reload_conversation_stream()

      {:error, :not_found} ->
        socket
    end
  end

  def build_initial_conversations(workspaces, _default_ws) do
    build_conversations_by_workspace(workspaces, include_archived?: true)
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
            workspace_id: ws_id,
            workspace_name: Map.get(ws_names, ws_id, ws_id),
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

  def workspace_conversations(conversations_by_workspace, ws_id, workspaces)
      when is_map(conversations_by_workspace) and is_list(workspaces) do
    ws_map = Map.new(workspaces, fn ws -> {ws["id"], ws["name"] || ws["id"]} end)

    conversations_by_workspace
    |> Map.get(ws_id, [])
    |> Enum.reject(&archived_conversation?/1)
    |> Enum.map(fn conv ->
      %{
        id: ConversationState.conversation_id(conv),
        title: ConversationState.conv_value(conv, "title", "New chat"),
        workspace_id: ws_id,
        workspace_name: Map.get(ws_map, ws_id, ws_id),
        archived: archived_conversation?(conv),
        updated_at: ConversationState.conv_value(conv, "updated_at", nil),
        created_at: ConversationState.conv_value(conv, "created_at", nil)
      }
    end)
  end

  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_conversation?(conversation) do
    case Map.get(conversation, "archived_at") do
      v when is_binary(v) and v != "" -> true
      _ -> false
    end
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
    ws_id = socket.assigns.current_workspace_id
    convs = Map.get(socket.assigns.conversations_by_workspace, ws_id, [])

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
