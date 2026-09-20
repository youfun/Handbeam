defmodule HandbeamProbe.HomeScreen.Nav do
  @moduledoc """
  Where the user is: page, workspace, conversation. Owns the transitions
  between them (`open/3`, `apply_workspace/3`, `blank/1`) and the composer
  reset that every context switch implies. Other domains call back here when
  a transition is the outcome of their work.
  """

  use Gettext, backend: HandbeamProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]

  alias HandbeamProbe.Bridge.Inbound

  alias HandbeamProbe.HomeScreen.{
    GitSettings,
    MCPSettings,
    Notice,
    Platform,
    Requests,
    Settings,
    Share,
    State
  }

  alias HandbeamProbe.{
    NativeApproval,
    NativeArtifactDelivery,
    NativeChat,
    NativeFileViewer,
    NativeWorkspaces,
    NativeWorkspaceTree,
    ShareIntake
  }

  alias Handbeam.{ConversationStore, WorkspaceStore}

  # ── dispatch ──

  def handle({:tap, {:conversation, id}}, socket) do
    with {:ok, conversation} <- ConversationStore.get(id),
         {:ok, workspace} <- WorkspaceStore.get(conversation["workspace_id"]) do
      if socket.assigns.workspace && socket.assigns.workspace["id"] == workspace["id"],
        do: open(socket, conversation),
        else: apply_workspace(socket, workspace, conversation)
    else
      _ -> Notice.put_error(socket, gettext("Conversation not found"))
    end
  end

  def handle({:tap, :toggle_inactive_history}, socket) do
    assign(socket, :inactive_history_open, not socket.assigns.inactive_history_open)
  end

  def handle({:tap, {:page, page}}, socket) do
    socket = socket |> assign(:page, page) |> Notice.clear()
    workspace = socket.assigns.workspace

    cond do
      is_nil(workspace) -> socket
      page == :history -> assign(socket, :history, HandbeamProbe.NativeHistory.load())
      page == :mcp -> MCPSettings.load(socket)
      page == :git -> GitSettings.load(socket)
      Settings.settings_page?(page) -> Settings.load_models(socket)
      page == :workspace -> assign(socket, :workspaces, NativeWorkspaces.load(workspace))
      page == :files -> NativeWorkspaceTree.ensure(socket)
      true -> socket
    end
  end

  def handle({:tap, {:workspace, id}}, socket) do
    case WorkspaceStore.get(id) do
      {:ok, workspace} ->
        apply_workspace(socket, workspace, NativeWorkspaces.resolve_conversation(workspace))

      _ ->
        Notice.put_error(socket, gettext("That workspace is no longer available"))
    end
  end

  def handle({:notification, %Inbound.Notification{} = notification}, socket) do
    %{conversation_id: id, workspace_id: workspace_id} = notification

    with true <- is_binary(id) and is_binary(workspace_id),
         {:ok, conversation} <- ConversationStore.get(id),
         true <- conversation["workspace_id"] == workspace_id,
         {:ok, workspace} <- WorkspaceStore.get(workspace_id) do
      apply_workspace(socket, workspace, conversation)
    else
      _ ->
        Notice.put_error(
          socket,
          gettext("The conversation in the notification is unavailable")
        )
    end
  end

  # ── transitions ──

  @doc "Show `conversation` in the current workspace. `keep_draft?` is the send path."
  def open(socket, conversation, keep_draft? \\ false) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, a.workspace, a.chat, a.draft)

    unsubscribe(a.chat)
    Handbeam.PubSub.Session.subscribe(conversation["id"])
    NativeWorkspaces.persist(a.workspace, conversation)

    draft =
      if keep_draft?,
        do: a.draft,
        else: NativeWorkspaces.get_draft(drafts, a.workspace, conversation)

    socket = if keep_draft?, do: socket, else: reset_composer(socket)

    drafts =
      if keep_draft?,
        do: NativeWorkspaces.clear_draft(drafts, a.workspace, nil),
        else: drafts

    socket
    |> assign(
      [
        chat: NativeChat.load(conversation),
        permission_mode: NativeApproval.mode(a.workspace),
        draft: draft,
        drafts: drafts,
        file_viewer: NativeFileViewer.new()
      ] ++ State.chat_reset()
    )
    |> bump_workspace_open()
    |> Settings.load_models()
  end

  @doc "Switch to `workspace`, showing `conversation` (or an empty chat)."
  def apply_workspace(socket, workspace, conversation) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, a.workspace, a.chat, a.draft)
    {_generation, socket} = Requests.bump(socket, :mcp_settings)
    {_generation, socket} = Requests.bump(socket, :git_settings)

    unsubscribe(a.chat)
    socket = reset_composer(socket)
    selected = NativeWorkspaces.selection(workspace, conversation)
    NativeWorkspaces.persist(selected.workspace, conversation)

    socket =
      socket
      |> assign(
        [
          workspace: selected.workspace,
          conversations: selected.conversations,
          permission_mode: selected.permission_mode,
          mcp: HandbeamProbe.MCPSettings.empty(),
          git: HandbeamProbe.GitSettings.empty(),
          drafts: drafts,
          workspace_tree: NativeWorkspaceTree.for_workspace(selected.workspace, a.workspace_tree),
          file_viewer: NativeFileViewer.new()
        ] ++ State.chat_reset()
      )
      |> bump_workspace_open()
      |> Settings.load_models()

    case conversation do
      nil ->
        assign(socket,
          chat: nil,
          draft: NativeWorkspaces.get_draft(drafts, selected.workspace, nil)
        )

      conversation ->
        Handbeam.PubSub.Session.subscribe(conversation["id"])

        assign(socket,
          chat: NativeChat.load(conversation),
          draft: NativeWorkspaces.get_draft(drafts, selected.workspace, conversation)
        )
    end
  end

  @doc "Leave the current conversation for an empty chat without touching the composer."
  def blank(socket) do
    a = socket.assigns
    drafts = NativeWorkspaces.put_draft(a.drafts, a.workspace, a.chat, a.draft)

    unsubscribe(a.chat)
    NativeWorkspaces.persist(a.workspace, nil)

    assign(socket, [chat: nil, drafts: drafts, draft: ""] ++ State.chat_reset())
  end

  @doc "Create the conversation for a first send when none is open."
  def ensure_conversation(%{assigns: %{chat: nil}} = socket) do
    case ConversationStore.create(socket.assigns.workspace["id"],
           title: conversation_title(socket)
         ) do
      {:ok, conversation} -> {:ok, open(socket, conversation, true)}
      error -> error
    end
  end

  def ensure_conversation(socket), do: {:ok, socket}

  def current_conversation_id(socket) do
    case socket.assigns.chat do
      %{conversation: %{"id" => id}} -> id
      _ -> nil
    end
  end

  @doc """
  Drop draft attachments, in-flight platform requests, delivery bindings and
  merged share intakes (returned to review) when the chat context changes.
  """
  def reset_composer(socket) do
    a = socket.assigns
    Platform.cleanup_draft_files(a.pending_attachments)
    returning = MapSet.to_list(a.merged_intake_ids)

    socket
    |> cancel_composer_requests()
    |> NativeArtifactDelivery.cleanup_bindings()
    |> assign(
      pending_attachments: [],
      input_warning: nil,
      composer_open_id: nil,
      composer_select: nil,
      timeline_open: nil,
      merged_intake_ids: MapSet.new(),
      share_send: nil,
      approval_snapshots: %{},
      deliver_mode: :steer,
      composer_mode: :chat,
      review_place: "",
      review_feeling: ""
    )
    |> then(&Notice.put(&1, Notice.clear_kind(&1.assigns.notice, :info)))
    |> Share.refresh(before: fn -> Enum.each(returning, &ShareIntake.return_to_review/1) end)
  end

  def unsubscribe(nil), do: :ok

  def unsubscribe(chat) do
    if ref = chat.reload_timer, do: Process.cancel_timer(ref)
    Handbeam.PubSub.Session.unsubscribe(chat.conversation["id"])
  end

  def conversations(workspace), do: ConversationStore.list_for_workspace(workspace["id"])

  # Every in-flight request bound to the composer (platform requests keyed by
  # request id, `:share_send_marked` tasks) is dropped from the table and the
  # host side is told to cancel; then the scope moves on so late replies are
  # superseded.
  defp cancel_composer_requests(socket) do
    {entries, socket} = Requests.drop_scope(socket, :composer)

    Enum.each(entries, fn entry ->
      if is_binary(entry.ref),
        do: HandbeamProbe.Platform.cancel(self(), entry.ref, entry.generation)
    end)

    {_generation, socket} = Requests.bump(socket, :composer)
    socket
  end

  defp bump_workspace_open(socket) do
    {_generation, socket} = Requests.bump(socket, :workspace_open)
    socket
  end

  defp conversation_title(socket) do
    text = String.trim(socket.assigns.draft)

    cond do
      text != "" ->
        String.slice(text, 0, 40)

      match?([_ | _], socket.assigns.pending_attachments) ->
        # Draft attachments are string-keyed (`Platform.add_attachment/2`).
        att = hd(socket.assigns.pending_attachments)
        att["filename"] || gettext("Attachment")

      true ->
        gettext("New conversation")
    end
  end
end
