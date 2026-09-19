defmodule HandbeamProbe.HomeScreen do
  @moduledoc """
  Native Mob chat shell. No LiveView or WebView in the product UI.

  This module only mounts, dispatches and renders. `socket.assigns` is a
  `HandbeamProbe.HomeScreen.State`; each message is routed to the domain that
  owns it (`Chat`, `Nav`, `Share`, `Platform`, `Delivery`, `FileNav`,
  `Settings`), and every domain `handle/2` is `socket -> socket`.

  Every message first passes `HandbeamProbe.Bridge.Inbound.decode/1`: host
  shapes (`engine_result`, `notification`, `files picked`) become structs,
  everything else passes through. Off-screen work started under
  `HandbeamProbe.TaskSupervisor` comes back as `{ref, {tag, generation, result}}`
  (see `HandbeamProbe.HomeScreen.Async`) and is correlated through
  `HandbeamProbe.HomeScreen.Requests` before it is routed by `tag`; stale or
  mismatched replies are dropped and the matching `:DOWN` is ignored.
  `{:pending_request_timeout, ref}` expires a request whose deadline passed.
  """

  use Mob.Screen
  use Gettext, backend: HandbeamProbe.Gettext

  require Logger

  alias HandbeamProbe.HomeScreen.{
    Chat,
    Delivery,
    FileNav,
    Nav,
    Notice,
    Platform,
    Render,
    Requests,
    Settings,
    Share,
    State
  }

  alias HandbeamProbe.{Bridge.Inbound, NativeApproval, NativeWorkspaces, PendingRequests, ShareCopy}
  alias Handbeam.WorkspaceStore

  @toggles [:toggle_tool_work, :toggle_work_segment, :toggle_tool_output]
  @chat_taps [
    :send,
    :stop,
    :new_chat,
    :dismiss_approval,
    :review_approval,
    :toggle_deliver_mode,
    :toggle_composer_mode,
    :generate_review
  ]
  @viewer_taps [:close_file_viewer, :file_viewer_open_external, :file_viewer_share]

  @workspace_taps [
    :open_create,
    :create_workspace,
    :workspace_list,
    :open_browse,
    :start_import,
    :cancel_import
  ]

  @timeout_message PendingRequests.timeout_message()

  # ── mount ──

  def mount(_params, _session, socket) do
    # Process-global so HandbeamWeb.Gettext copy (e.g. Intent outcomes) follows too.
    Gettext.put_locale(HandbeamProbe.Gettext.locale())

    case WorkspaceStore.ensure_default!() do
      {:ok, default} ->
        Phoenix.PubSub.subscribe(Handbeam.PubSub, "models:updated")
        {workspace, conversation} = NativeWorkspaces.restore(default)

        socket =
          socket
          |> put_state(
            workspace: workspace,
            permission_mode: NativeApproval.mode(workspace),
            conversations: Nav.conversations(workspace),
            workspaces: NativeWorkspaces.load(workspace)
          )
          |> Settings.load_models()

        socket = if conversation, do: Nav.open(socket, conversation), else: socket

        # Boot reconcile of interrupted copies runs in the same task as the first
        # listing so the review FIFO cannot be listed before it.
        {:ok, Share.refresh(socket, before: fn -> ShareCopy.reconcile(abandon_all: true) end)}

      _ ->
        {:ok,
         put_state(socket,
           workspace: nil,
           notice: Notice.error(gettext("Workspace initialization failed"))
         )}
    end
  end

  # Keys Mob placed in assigns before mount (e.g. safe area) survive on the struct.
  defp put_state(socket, overrides),
    do: %{socket | assigns: Map.merge(State.new(overrides), socket.assigns)}

  # ── dispatch ──

  def handle_info(message, socket) do
    case Inbound.decode(message) do
      {:ok, decoded} ->
        {:noreply, dispatch(decoded, socket)}

      {:error, reason} ->
        Inbound.drop(message, reason)
        {:noreply, socket}
    end
  end

  # async task replies (Task.Supervisor.async_nolink) and their :DOWN
  defp dispatch({ref, {tag, generation, result}}, socket)
       when is_reference(ref) and is_atom(tag) do
    Process.demonitor(ref, [:flush])
    task_result(socket, ref, tag, generation, result)
  end

  defp dispatch({ref, {tag, generation, target, result}}, socket)
       when is_reference(ref) and is_atom(tag) do
    Process.demonitor(ref, [:flush])
    task_result(socket, ref, tag, generation, {target, result})
  end

  defp dispatch({:DOWN, _ref, :process, _pid, _reason}, socket), do: socket

  defp dispatch({@timeout_message, ref}, socket) do
    case Requests.expire(socket, ref) do
      {:ok, entry, socket} -> Platform.handle_timeout(socket, entry)
      :error -> socket
    end
  end

  # chat
  defp dispatch({:change, :draft, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:change, :review_place, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:change, :review_feeling, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:submit, :send} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, tap} = msg, socket) when tap in @chat_taps, do: Chat.handle(msg, socket)

  defp dispatch({:tap, {toggle, _}} = msg, socket) when toggle in @toggles,
    do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:cancel_pending, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:resend_pending, _}} = msg, socket), do: Chat.handle(msg, socket)

  defp dispatch({:tap, {:tool_action, _, _, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tool_action_result, _, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:composer_select, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:permission_mode, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:tap, {:approval, _, _, _, _}} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:agent_event, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:reload_transcript, _} = msg, socket), do: Chat.handle(msg, socket)
  defp dispatch({:alert, :cancel_all_runs} = msg, socket), do: Chat.handle(msg, socket)

  # navigation
  defp dispatch({kind, :dismiss_input_warning}, socket) when kind in [:tap, :dismiss],
    do: Mob.Socket.assign(socket, :input_warning, nil)

  defp dispatch({:tap, :toggle_inactive_history} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:conversation, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:page, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:tap, {:workspace, _}} = msg, socket), do: Nav.handle(msg, socket)
  defp dispatch({:notification, _} = msg, socket), do: Nav.handle(msg, socket)

  # share intake
  defp dispatch({:share_intake_ready, _, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_workspace_result, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_rollback, _, _} = msg, socket), do: Share.handle(msg, socket)
  defp dispatch({:share_cleanup, _, _} = msg, socket), do: Share.handle(msg, socket)

  defp dispatch({:tap, {share, _}} = msg, socket)
       when share in [:share_confirm, :share_confirm_new, :share_discard],
       do: Share.handle(msg, socket)

  # platform requests, attachments, image cards
  defp dispatch({:change, field, _} = msg, socket)
       when field in [:artifact_path, :open_url_draft],
       do: Platform.handle(msg, socket)

  defp dispatch({:tap, {:platform, :begin, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:platform, _, _} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:platform, _, _, _} = msg, socket), do: Platform.handle(msg, socket)

  defp dispatch({:engine_result, %Inbound.EngineResult{}} = msg, socket),
    do: Platform.handle(msg, socket)

  defp dispatch({:tap, {:remove_attachment, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:tap, {:open_draft_image, _}} = msg, socket), do: Platform.handle(msg, socket)
  defp dispatch({:tap, {:open_sent_image, _, _}} = msg, socket), do: Platform.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in [:close_draft_image, :close_sent_image],
    do: Platform.handle(msg, socket)

  # system delivery
  defp dispatch({:tap, {:delivery, _}} = msg, socket), do: Delivery.handle(msg, socket)
  defp dispatch({:tap, {:delivery, _, _}} = msg, socket), do: Delivery.handle(msg, socket)

  # files, workspace page, directory picker
  defp dispatch({:tap, {:workspace_open, :view, _}} = msg, socket),
    do: FileNav.handle(msg, socket)

  defp dispatch({:workspace_open_ready, _, _} = msg, socket), do: FileNav.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in @viewer_taps,
    do: FileNav.handle(msg, socket)

  defp dispatch({:tap, {:file_tree, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:file_tree_listed, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:change, :workspace_name, _} = msg, socket), do: FileNav.handle(msg, socket)

  defp dispatch({:tap, tap} = msg, socket) when tap in @workspace_taps,
    do: FileNav.handle(msg, socket)

  defp dispatch({:tap, {:browse, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:tap, {:toggle_path, _}} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:files, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:files, _, _} = msg, socket), do: FileNav.handle(msg, socket)
  defp dispatch({:directory_picker, _} = msg, socket), do: FileNav.handle(msg, socket)

  # model / AI settings
  defp dispatch({:tap, {:composer_setting, field, _}} = msg, %{assigns: %{page: :chat}} = socket)
       when field in [:default_model, :reasoning],
       do: Settings.handle(msg, socket)

  defp dispatch({:change, {:model_field, _}, _} = msg, socket), do: Settings.handle(msg, socket)
  defp dispatch({:dismiss, :cancel_confirm} = msg, socket), do: Settings.handle(msg, socket)
  defp dispatch({:models_updated} = msg, socket), do: Settings.handle(msg, socket)

  defp dispatch({:tap, _} = msg, %{assigns: %{page: page}} = socket) do
    if Settings.settings_page?(page), do: Settings.handle(msg, socket), else: socket
  end

  defp dispatch(_message, socket), do: socket

  # A tracked reply is routed only when `PendingRequests.take/3` accepts it:
  # the ref is registered, the wire generation equals the registered one and
  # the scope has not moved on. Untracked (`Async.fire/2`) replies are unknown
  # to the table and ignored; stale ones are logged and dropped.
  defp task_result(socket, ref, tag, generation, result) do
    case Requests.take(socket, ref, generation) do
      {:ok, %PendingRequests.Entry{kind: ^tag}, socket} ->
        async_result(tag, result, socket)

      {:ok, entry, socket} ->
        Logger.warning("[home] task reply #{tag} for #{entry.kind} entry dropped")
        socket

      {:error, :unknown, socket} ->
        socket

      {:error, reason, socket} ->
        Logger.debug("[home] stale task reply #{tag} dropped: #{inspect(reason)}")
        socket
    end
  end

  defp async_result(:share_intakes_ready, result, socket),
    do: Share.handle_ready(socket, result)

  defp async_result(:share_send_marked, result, socket) do
    case Share.handle_send_marked(socket, result) do
      {:send, socket, inbound_id, deliver_as, composer_mode} ->
        Chat.send_after_intake_pending(socket, inbound_id, deliver_as, composer_mode)

      {:noop, socket} ->
        socket
    end
  end

  defp async_result(:folder_listed, result, socket),
    do: FileNav.handle_folder_listed(socket, result)

  defp async_result(:model_settings_loaded, result, socket),
    do: Settings.handle_loaded(socket, result)

  defp async_result(:model_settings_refs, {target, result}, socket),
    do: Settings.handle_refs(socket, target, result)

  defp async_result(_kind, _result, socket), do: socket

  # ── render ──

  def render(a), do: Render.render(a)
end
