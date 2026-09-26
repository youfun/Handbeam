defmodule HandbeamWeb.WorkspaceLive do
  @moduledoc """
  Main workspace LiveView — three-column layout with workspace/project sidebar.

  Layout:
  ┌──────────┬───────────────────┬───────────────────┐
  │ Projects │   Chat / AI Panel │   Workspace       │
  │ (Left)   │   (Center)        │   (Right)         │
  └──────────┴───────────────────┴───────────────────┘
                 StatusBar (bottom)

  Left sidebar shows workspaces (projects) with conversations grouped
  underneath. Each conversation is bound to a workspace, and the Agent
  working_directory is always the current conversation's workspace path.
  """

  use HandbeamWeb, :live_view

  require Logger

  alias HandbeamWeb.WorkspaceLive.Approval
  alias HandbeamWeb.WorkspaceLive.Composer
  alias HandbeamWeb.WorkspaceLive.ConversationState
  alias HandbeamWeb.WorkspaceLive.ConversationSwitching
  alias HandbeamWeb.WorkspaceLive.EditorProjection
  alias HandbeamWeb.WorkspaceLive.MessageSubmission
  alias HandbeamWeb.WorkspaceLive.ModelSelection
  alias HandbeamWeb.WorkspaceLive.RuntimeProjection
  alias HandbeamWeb.WorkspaceLive.Skills
  alias HandbeamWeb.WorkspaceLive.ViewComponents
  alias HandbeamWeb.WorkspaceLive.WorkspaceNavigation

  import ViewComponents,
    only: [
      mobile_header: 1,
      projects_sidebar: 1,
      chat_panel: 1,
      workspace_panel: 1,
      mobile_sheets: 1,
      approval_overlay: 1,
      status_bar: 1
    ]

  alias Handbeam.WorkspaceFiles

  @impl true
  def mount(_params, _session, socket) do
    # Ensure default workspace exists
    {:ok, default_ws} = Handbeam.WorkspaceStore.ensure_default!()

    workspaces = Handbeam.WorkspaceStore.list()

    # Initialize conversations: one empty conversation per workspace
    conversations_by_ws = build_initial_conversations(workspaces, default_ws)
    log_workspace_boot(default_ws, workspaces, conversations_by_ws)

    current_ws_id = default_ws["id"]
    current_conv_id = initial_conversation_id(conversations_by_ws, current_ws_id)

    workspace_root = default_ws["path"]
    Handbeam.Workspace.ensure_root!()
    workspace_label = default_ws["name"]

    models = ModelSelection.boot(workspace_root)
    available_models = models.available_models
    selected_model = models.selected_model
    selected_reasoning_level = models.selected_reasoning_level
    available_reasoning_levels = models.available_reasoning_levels

    # Detect mobile mode from UA on initial render (JS will correct after mount)
    mobile_mode = WorkspaceNavigation.mobile_mode_from_ua(get_connect_params(socket))

    socket =
      socket
      |> assign(:page_title, "Handbeam — Workspace")
      |> assign(:chat_scope, :workspace)
      |> assign(:workspaces, workspaces)
      |> assign(:current_workspace_id, current_ws_id)
      |> assign(:current_conversation_id, current_conv_id)
      |> assign(:workspace_root, workspace_root)
      |> assign(:workspace_label, workspace_label)
      |> assign(:conversations_by_workspace, conversations_by_ws)
      |> assign(:selected_model, selected_model)
      |> assign(:available_models, available_models)
      |> assign(:selected_reasoning_level, selected_reasoning_level)
      |> assign(:available_reasoning_levels, available_reasoning_levels)
      |> assign(:status_info, %{
        model: models.status_model,
        input_tokens: 0,
        total_input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        status: :idle,
        turns: 0
      })
      |> stream_configure(:timeline, dom_id: &timeline_entry_id/1)
      # Build conversation stream (flat list, scroll-safe)
      |> stream_conversations(conversations_by_ws, workspaces)
      # Current conversation state (mirrored from conversations for convenience)
      |> ConversationState.sync_conv_state()
      # Add project dialog
      |> assign(:show_add_project, false)
      |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})
      |> assign(:show_file_browser, false)
      |> assign(:file_browser_path, nil)
      |> assign(:sandbox_workspace?, WorkspaceNavigation.sandbox_workspace?())
      |> subscribe_workspace_import()
      |> assign(:terminal_available?, Handbeam.Host.terminal?())
      |> assign(:show_terminal, false)
      |> assign(:right_panel_view, :files)
      |> assign(:workspace_tree, %{})
      |> assign(:expanded_workspace_dirs, MapSet.new())
      |> assign(:workspace_tree_error, nil)
      |> WorkspaceNavigation.load_workspace_tree("")
      # Thinking / reasoning display
      |> assign(:thinking_content, "")
      |> assign(:thinking_active, false)
      |> assign(:think_buffer, "")
      # Agent state
      |> assign(:input_value, "")
      |> assign(:composer_error, nil)
      |> assign(:running, false)
      |> assign(:running_conversation_id, nil)
      |> assign(:stream_suppressed, false)
      |> assign(:pending_attachments, [])
      |> assign(:pending_messages, %{})
      |> allow_upload(:images,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 4,
        max_file_size: 5_000_000,
        auto_upload: true
      )
      |> ModelSelection.reload_workspace_counts()
      |> assign(:expanded_file_changes, MapSet.new())
      |> assign(:revert_confirm_change_id, nil)
      |> assign(:revert_message, nil)
      |> assign(:current_assistant_entry_id, nil)
      |> assign(:tools_active, %{})
      |> assign(:expanded_tool_groups, MapSet.new())
      |> assign(:show_archive, false)
      |> assign(:collapsed_workspace_ids, MapSet.new())
      |> assign(:workspace_menu_id, nil)
      |> assign(:remove_workspace, nil)
      |> assign(:conversation_menu_id, nil)
      |> assign(:rename_conversation, nil)
      |> assign(:pending_approval, nil)
      |> assign(:show_permission_menu, false)
      |> assign(:skill_suggestions, [])
      |> assign(:ext_status_text, nil)
      |> assign(:ext_notification, nil)
      |> assign(:ext_widget_data, nil)
      |> WorkspaceNavigation.load_permission_mode_into_socket()
      |> subscribe_to_conversation_updates()
      |> RuntimeProjection.subscribe_session()
      |> RuntimeProjection.subscribe_tasks()
      |> RuntimeProjection.restore_active_session()
      |> load_available_skills()
      # Mobile mode
      |> assign(:mobile_mode, mobile_mode)
      # Mobile UI overlays
      |> assign(:show_workspace_sheet, false)
      |> assign(:show_model_sheet, false)
      |> assign(:show_reasoning_sheet, false)
      |> assign(:show_settings_sheet, false)
      |> assign(:show_file_drawer, false)
      |> assign(:show_settings_panel, false)
      |> assign(:mobile_right_panel_open, false)
      |> assign(:right_panel_collapsed, false)
      |> ModelSelection.load_effective_settings()
      |> ModelSelection.apply_effective()

    {:ok, socket}
  end

  @impl true
  def handle_params(
        %{"conversation_id" => conv_id},
        _uri,
        %{assigns: %{live_action: :free}} = socket
      ) do
    with {:ok, conv} <- Handbeam.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbeam.ConversationStore.free?(conv) do
      socket =
        if socket.assigns.current_conversation_id == conv_id and
             socket.assigns.chat_scope == :free do
          socket
        else
          {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

          socket
          |> WorkspaceNavigation.enter_free_chat()
          |> RuntimeProjection.subscribe_session()
          |> RuntimeProjection.restore_active_session()
          |> WorkspaceNavigation.close_mobile_sheets()
        end

      {:noreply, socket}
    else
      _ -> {:noreply, push_patch(socket, to: "/")}
    end
  end

  def handle_params(
        %{"workspace_id" => ws_id, "conversation_id" => conv_id} = _params,
        _uri,
        socket
      ) do
    if socket.assigns.current_workspace_id != ws_id or
         socket.assigns.current_conversation_id != conv_id do
      with {:ok, ws} <- Handbeam.WorkspaceStore.get(ws_id),
           {:ok, conv} <- Handbeam.ConversationStore.get(conv_id, include_timeline?: false),
           true <- conv["workspace_id"] == ws_id do
        {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

        socket =
          socket
          |> assign(:workspace_root, ws["path"])
          |> assign(:workspace_label, ws["name"])
          |> WorkspaceNavigation.after_switch()
          |> RuntimeProjection.subscribe_session()
          |> RuntimeProjection.restore_active_session()
          |> WorkspaceNavigation.close_mobile_sheets()

        {:noreply, socket}
      else
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_progress(:images, entry, socket) do
    errors =
      entry.errors
      |> Enum.map(&Composer.upload_error/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    socket =
      if errors != [] do
        assign(socket, :composer_error, Enum.join(errors, "; "))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_attachment", %{"id" => id}, socket) do
    {:noreply, Composer.remove_attachment(socket, id)}
  end

  @impl true
  def handle_event("clear_composer_error", _params, socket) do
    {:noreply, assign(socket, :composer_error, nil)}
  end

  @impl true
  def handle_event("toggle_skills_panel", _params, socket) do
    {:noreply, update(socket, :show_skills_panel, &(!&1))}
  end

  @impl true
  def handle_event("launch_skill", %{"name" => skill_name}, socket) do
    prompt = Skills.launch_prompt(socket.assigns.available_skills, skill_name)

    socket =
      socket
      |> assign(:show_skills_panel, false)
      |> assign(:input_value, prompt)

    {:noreply, socket}
  end

  @impl true
  def handle_event("composer_drop", params, socket) do
    # Form-level phx-change also fires when the model/reasoning <select>
    # changes. Ignore those params and the picker snaps back on remorph.
    socket = ModelSelection.apply_submitted(socket, params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", params, socket),
    do: MessageSubmission.send_message(socket, params)

  @impl true
  def handle_event("steer_message", params, socket),
    do: MessageSubmission.steer_message(socket, params)

  @impl true
  def handle_event("queue_message", params, socket),
    do: MessageSubmission.queue_message(socket, params)

  @impl true
  def handle_event("cancel_pending", %{"id" => id}, socket),
    do: MessageSubmission.cancel_pending(socket, id)

  @impl true
  def handle_event("resend_pending", %{"id" => id}, socket),
    do: MessageSubmission.resend_pending(socket, id)

  @impl true
  def handle_event("update_input", %{"value" => value}, socket) do
    suggestions = Skills.suggestions(value, socket.assigns.available_skills)

    {:noreply,
     socket
     |> assign(:input_value, value)
     |> assign(:skill_suggestions, suggestions)}
  end

  @impl true
  def handle_event("select_skill_suggestion", %{"name" => skill_name}, socket) do
    new_value = Skills.select(socket.assigns.input_value, skill_name)

    {:noreply,
     socket
     |> assign(:input_value, new_value)
     |> assign(:skill_suggestions, nil)}
  end

  @impl true
  def handle_event("dismiss_skill_suggestions", _params, socket) do
    {:noreply, assign(socket, :skill_suggestions, nil)}
  end

  @impl true
  def handle_event("stop_run", _params, socket), do: MessageSubmission.stop(socket)

  def handle_event("approve_all_tools", params, socket) do
    resume_tool_approval(socket, :approve, Approval.remember_scope(params))
  end

  def handle_event("deny_all_tools", params, socket) do
    resume_tool_approval(socket, :deny, Approval.remember_scope(params))
  end

  @impl true
  def handle_event("select_model", params, socket) do
    {:noreply, ModelSelection.select(socket, params["model"] || params["value"])}
  end

  @impl true
  def handle_event("select_reasoning", %{"reasoning" => level}, socket) do
    {:noreply, ModelSelection.select_reasoning(socket, level)}
  end

  @impl true
  def handle_event("refresh_models", _params, socket) do
    {:noreply, ModelSelection.refresh(socket)}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    socket =
      ConversationState.select_file(
        socket,
        path,
        ConversationState.current_workspace_path(socket),
        ModelSelection.state_opts()
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_workspace_file", %{"path" => relative_path}, socket) do
    case WorkspaceFiles.resolve(
           ConversationState.current_workspace_path(socket),
           relative_path,
           :file
         ) do
      {:ok, path} ->
        socket =
          ConversationState.select_file(
            socket,
            path,
            ConversationState.current_workspace_path(socket),
            ModelSelection.state_opts()
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_workspace_directory", %{"path" => relative_path}, socket) do
    {:noreply, WorkspaceNavigation.toggle_directory(socket, relative_path)}
  end

  @impl true
  def handle_event("select_right_panel_view", %{"view" => view}, socket)
      when view in ["changes", "files"] do
    {:noreply, WorkspaceNavigation.select_panel(socket, view)}
  end

  def handle_event("select_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "files"}, socket) do
    {:noreply, WorkspaceNavigation.show_files_mobile(socket)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket, true)}
  end

  def handle_event("close_mobile_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.close_mobile_panel(socket)}
  end

  def handle_event("toggle_file_change", params, socket) do
    case params do
      %{"id" => id} when is_binary(id) ->
        expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())

        expanded =
          if MapSet.member?(expanded, id),
            do: MapSet.delete(expanded, id),
            else: MapSet.put(expanded, id)

        {:noreply,
         socket
         |> assign(:expanded_file_changes, expanded)
         |> assign(:right_panel_collapsed, false)
         |> RuntimeProjection.refresh_file_change(id)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_revert_change", %{"change_id" => change_id}, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, change_id)}
  end

  @impl true
  def handle_event("cancel_revert_change", _params, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, nil)}
  end

  @impl true
  def handle_event("revert_change", %{"change_id" => change_id}, socket) do
    with %{} = change <- find_change(socket.assigns.timeline, change_id),
         {:not_running, false} <- {:not_running, running_for_current_conversation?(socket)} do
      result =
        Handbeam.ChangeReverter.revert(change, ConversationState.current_workspace_path(socket))

      {:noreply,
       EditorProjection.apply_revert_result(
         socket,
         change,
         result,
         ConversationState.current_workspace_path(socket)
       )}
    else
      {:not_running, true} ->
        {:noreply,
         RuntimeProjection.mark_revert_confirm(
           assign(socket, :revert_message, %{
             "change_id" => change_id,
             "status" => "error",
             "message" => "Cannot revert while an agent run is active."
           }),
           nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_preview", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :overlay)}
  end

  @impl true
  def handle_event("open_preview_external", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :external)}
  end

  @impl true
  def handle_event("takeover_browser", %{"session" => session_id}, socket) do
    try do
      case Handbeam.Browser.WebViewSession.user_takeover(session_id) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "browser takeover failed: #{inspect(reason)}")}
      end
    catch
      :exit, _ -> {:noreply, put_flash(socket, :error, "browser session is gone")}
    end
  end

  def handle_event("toggle_terminal", _params, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  # ── Workspace / Project dialog ──

  @impl true
  def handle_event("open_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.open_add_project(socket)}
  end

  @impl true
  def handle_event("cancel_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_add_project(socket)}
  end

  @impl true
  def handle_event("update_add_path", %{"value" => path}, socket) do
    {:noreply, WorkspaceNavigation.update_add_path(socket, path)}
  end

  @impl true
  def handle_event("update_add_name", %{"value" => name}, socket) do
    {:noreply, WorkspaceNavigation.update_add_name(socket, name)}
  end

  @impl true
  def handle_event("confirm_add_project", _params, socket) do
    WorkspaceNavigation.confirm_add_event(socket)
  end

  def handle_event("browse_folder", _params, socket) do
    {:noreply, WorkspaceNavigation.browse_folder(socket)}
  end

  @impl true
  def handle_event("select_workspace", %{"id" => ws_id}, socket) do
    socket = WorkspaceNavigation.expand_group(socket, ws_id)
    {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws_id)

    socket =
      socket
      |> WorkspaceNavigation.after_switch()
      |> RuntimeProjection.subscribe_session()
      |> RuntimeProjection.restore_active_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  @impl true
  def handle_event("load_older_history", _params, socket) do
    {:noreply, ConversationState.load_older_history(socket)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    with {:ok, %{"workspace_id" => ^ws_id}} <-
           Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
      {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.after_switch()
        |> RuntimeProjection.subscribe_session()
        |> RuntimeProjection.restore_active_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_archived_conversation", %{"id" => conv_id, "ws" => ws_id}, socket) do
    with {:ok, %{"workspace_id" => ^ws_id}} <-
           Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
      {socket, _conv_id} =
        ConversationSwitching.select_archived_conversation(socket, ws_id, conv_id)

      socket =
        socket
        |> ConversationState.sync_conv_state(reload?: true)
        |> RuntimeProjection.subscribe_session()
        |> RuntimeProjection.restore_active_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_conversation_menu", %{"id" => conv_id}, socket) do
    menu_id = if socket.assigns.conversation_menu_id == conv_id, do: nil, else: conv_id
    {:noreply, assign(socket, :conversation_menu_id, menu_id)}
  end

  def handle_event("close_conversation_menu", _params, socket) do
    {:noreply, assign(socket, :conversation_menu_id, nil)}
  end

  @impl true
  def handle_event("open_rename_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    case Handbeam.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, %{"workspace_id" => ^ws_id, "title" => title}} ->
        {:noreply,
         socket
         |> assign(:conversation_menu_id, nil)
         |> assign(:rename_conversation, %{
           id: conv_id,
           workspace_id: ws_id,
           title: title || "",
           error: nil
         })}

      _ ->
        {:noreply, assign(socket, :conversation_menu_id, nil)}
    end
  end

  def handle_event("cancel_rename_conversation", _params, socket) do
    {:noreply, assign(socket, :rename_conversation, nil)}
  end

  def handle_event("confirm_rename_conversation", %{"title" => title}, socket) do
    case socket.assigns.rename_conversation do
      %{id: conv_id} = rename ->
        case Handbeam.ConversationStore.rename(conv_id, title) do
          {:ok, meta} ->
            {:noreply,
             socket
             |> ConversationSwitching.refresh_conversation_in_sidebar(conv_id)
             |> ConversationState.maybe_patch_page_title(conv_id, meta["title"])
             |> assign(:rename_conversation, nil)}

          {:error, :empty} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能为空")
             })}

          {:error, :too_long} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能超过 80 个字符")
             })}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("重命名失败")
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("archive_conversation", params, socket) do
    conv_id = params["id"]
    ws_id = params["ws_id"] || socket.assigns.current_workspace_id

    {socket, next_conv_id} =
      ConversationSwitching.archive_conversation(
        socket
        |> assign(:conversation_menu_id, nil)
        |> assign(:rename_conversation, nil),
        conv_id,
        ws_id,
        ModelSelection.state_opts()
      )

    socket =
      if next_conv_id do
        socket = RuntimeProjection.subscribe_session(socket)
        push_patch(socket, to: "/w/#{ws_id}/c/#{next_conv_id}")
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("unarchive_conversation", %{"id" => conv_id}, socket) do
    {:noreply, ConversationSwitching.unarchive_conversation(socket, conv_id)}
  end

  # ── Archive toggle ──

  @impl true
  def handle_event("toggle_archive", _params, socket) do
    {:noreply, update(socket, :show_archive, &(!&1))}
  end

  @impl true
  def handle_event("toggle_workspace_group", %{"id" => id}, socket)
      when is_binary(id) do
    {:noreply, WorkspaceNavigation.toggle_group(socket, id)}
  end

  @impl true
  def handle_event("toggle_workspace_menu", %{"id" => ws_id}, socket) do
    {:noreply, WorkspaceNavigation.toggle_workspace_menu(socket, ws_id)}
  end

  def handle_event("close_workspace_menu", _params, socket) do
    {:noreply, WorkspaceNavigation.close_workspace_menu(socket)}
  end

  @impl true
  def handle_event("open_remove_workspace", %{"id" => ws_id}, socket) do
    {:noreply, WorkspaceNavigation.open_remove_workspace(socket, ws_id)}
  end

  def handle_event("cancel_remove_workspace", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_remove_workspace(socket)}
  end

  @impl true
  def handle_event("confirm_remove_workspace", _params, socket) do
    case socket.assigns.remove_workspace do
      %{id: ws_id} ->
        case ConversationSwitching.remove_workspace(socket, ws_id) do
          {:ok, socket, _removed} ->
            socket =
              if socket.assigns.current_workspace_id == ws_id do
                WorkspaceNavigation.switch_away_from_removed_workspace(socket)
              else
                socket
              end

            {:noreply, socket}

          {:error, :default_workspace} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("默认工作区不能移除"))}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("移除工作区失败"))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    ws_id = socket.assigns.current_workspace_id

    {socket, conv_id} =
      ConversationSwitching.new_conversation(socket, ws_id, ModelSelection.switching_opts())

    socket =
      socket
      |> WorkspaceNavigation.expand_group(ws_id)
      |> RuntimeProjection.subscribe_session()

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  @impl true
  def handle_event("new_free_conversation", _params, socket) do
    {socket, conv_id} =
      ConversationSwitching.new_free_conversation(socket, ModelSelection.switching_opts())

    socket =
      socket
      |> WorkspaceNavigation.expand_group("free")
      |> WorkspaceNavigation.enter_free_chat()
      |> RuntimeProjection.subscribe_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
  end

  @impl true
  def handle_event("select_free_conversation", %{"id" => conv_id}, socket) do
    with {:ok, conv} <- Handbeam.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbeam.ConversationStore.free?(conv) do
      {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.enter_free_chat()
        |> RuntimeProjection.subscribe_session()
        |> RuntimeProjection.restore_active_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_conversation_in_workspace", %{"ws_id" => ws_id}, socket) do
    create_conversation_in_workspace(socket, ws_id, close_sheets?: false)
  end

  @impl true
  def handle_event("mobile_new_conversation_in_workspace", %{"ws_id" => ws_id}, socket) do
    create_conversation_in_workspace(socket, ws_id, close_sheets?: true)
  end

  @impl true
  def handle_event("open_settings", _, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         settings_href(
           socket.assigns.current_workspace_id,
           socket.assigns.current_conversation_id
         )
     )}
  end

  @impl true
  def handle_event("open_sheet", %{"type" => type}, socket) do
    {:noreply, WorkspaceNavigation.open_sheet(socket, type)}
  end

  @impl true
  def handle_event("close_sheets", _params, socket) do
    {:noreply, WorkspaceNavigation.close_sheet_panels(socket)}
  end

  @impl true
  def handle_event("select_model_from_sheet", %{"model" => model}, socket) do
    {:noreply, ModelSelection.select_from_sheet(socket, model)}
  end

  @impl true
  def handle_event("select_reasoning_from_sheet", %{"level" => level}, socket) do
    {:noreply, ModelSelection.select_reasoning_from_sheet(socket, level)}
  end

  @impl true
  def handle_event("toggle_file_drawer", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_file_drawer(socket)}
  end

  @impl true
  def handle_event("toggle_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_right_panel(socket)}
  end

  @impl true
  def handle_event("set_right_panel_collapsed", %{"collapsed" => collapsed}, socket) do
    {:noreply, WorkspaceNavigation.set_right_panel_collapsed(socket, collapsed)}
  end

  def handle_event("toggle_tool_work", %{"group" => group_id}, socket)
      when is_binary(group_id) and group_id != "" do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    expanded =
      if MapSet.member?(expanded, group_id) do
        MapSet.delete(expanded, group_id)
      else
        MapSet.put(expanded, group_id)
      end

    {:noreply,
     socket
     |> assign(:expanded_tool_groups, expanded)
     |> RuntimeProjection.refresh_tool_work(group_id)}
  end

  def handle_event("toggle_tool_work", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_permission_menu", _params, socket) do
    {:noreply, update(socket, :show_permission_menu, &(!&1))}
  end

  @impl true
  def handle_event("select_permission_mode", %{"mode" => "auto_review"}, socket) do
    workspace_root = socket.assigns.workspace_root || Handbeam.Workspace.root()

    case Handbeam.WorkspaceSettings.update_approvals_reviewer(workspace_root, :auto_review) do
      :ok ->
        Logger.info(
          "[WorkspaceLive] Updated approvals_reviewer to auto_review in #{workspace_root}"
        )

        {:noreply,
         socket
         |> assign(:permission_mode, :auto_review)
         |> assign(:show_permission_menu, false)}

      {:error, reason} ->
        Logger.error("[WorkspaceLive] Failed to update approvals_reviewer: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_permission_menu, false)
         |> put_flash(:error, gettext("Failed to update permission mode"))}
    end
  end

  def handle_event("select_permission_mode", %{"mode" => mode_str}, socket) do
    mode = Handbeam.Permissions.ApprovalMode.parse(mode_str, :auto)
    workspace_root = socket.assigns.workspace_root || Handbeam.Workspace.root()

    with :ok <- Handbeam.WorkspaceSettings.update_default_mode(workspace_root, mode),
         :ok <- Handbeam.WorkspaceSettings.update_approvals_reviewer(workspace_root, :user) do
      Logger.info("[WorkspaceLive] Updated tool default_mode to #{mode} in #{workspace_root}")

      {:noreply,
       socket
       |> assign(:permission_mode, mode)
       |> assign(:show_permission_menu, false)}
    else
      {:error, reason} ->
        Logger.error("[WorkspaceLive] Failed to update tool default_mode: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_permission_menu, false)
         |> put_flash(:error, gettext("Failed to update permission mode"))}
    end
  end

  @impl true
  def handle_event("scroll_to_bottom", _params, socket) do
    {:noreply, push_event(socket, "scroll_chat_to_bottom", %{})}
  end

  defp create_conversation_in_workspace(socket, ws_id, opts) do
    {socket, conv_id} =
      ConversationSwitching.new_conversation(socket, ws_id, ModelSelection.switching_opts())

    socket =
      socket
      |> WorkspaceNavigation.expand_group(ws_id)
      |> WorkspaceNavigation.after_switch()
      |> RuntimeProjection.subscribe_session()

    socket =
      if Keyword.get(opts, :close_sheets?, false) do
        WorkspaceNavigation.close_mobile_sheets(socket)
      else
        socket
      end

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  # ── Workspace / Conversation switching ──

  @impl true
  def handle_info({:settings_saved, effective}, socket) do
    Logger.debug("[WorkspaceLive] settings saved, om_enabled=#{effective.om_enabled}")

    {:noreply,
     socket
     |> assign(:show_settings_panel, false)
     |> assign(:effective_settings, effective)
     |> ModelSelection.apply_effective()}
  end

  def handle_info(:settings_closed, socket) do
    {:noreply, assign(socket, :show_settings_panel, false)}
  end

  # ── Agent events ──

  @impl true
  def handle_info({:file_browser_closed}, socket) do
    {:noreply, WorkspaceNavigation.close_file_browser(socket)}
  end

  @impl true
  def handle_info({:folder_selected_from_browser, path}, socket) do
    {:noreply, WorkspaceNavigation.folder_selected(socket, path)}
  end

  def handle_info({:workspace_imported, item}, socket) when is_map(item) do
    {:noreply, WorkspaceNavigation.import_workspace(socket, item)}
  end

  @impl true
  def handle_info({:agent_event, event}, socket) do
    {:noreply, RuntimeProjection.apply(socket, event)}
  end

  def handle_info(%Handbeam.PubSub.AgentEvent{} = event, socket) do
    {:noreply, RuntimeProjection.apply(socket, event)}
  end

  def handle_info({:runtime_tasks, snapshot}, socket) do
    {:noreply, assign(socket, :runtime_tasks, snapshot)}
  end

  def handle_info({:in_app_ended, task, reason}, socket) do
    if task.conversation_id == socket.assigns.current_conversation_id do
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :info, in_app_ended_flash(task, reason))}
    end
  end

  def handle_info({:conversation_updated, conv_id}, socket) do
    socket =
      socket
      |> refresh_conversation_in_sidebar(conv_id)
      |> ConversationState.maybe_patch_current_page_title(conv_id)

    if socket.assigns.current_conversation_id == conv_id do
      send(self(), {:conversation_handoffs, conv_id})
    end

    {:noreply, socket}
  end

  def handle_info({:conversation_title_ready, conv_id, title}, socket)
      when is_binary(conv_id) and is_binary(title) do
    {:noreply,
     socket
     |> apply_sidebar_title(conv_id, title)
     |> ConversationState.maybe_patch_page_title(conv_id, title)}
  end

  def handle_info({:conversation_handoffs, conv_id}, socket) do
    socket =
      if socket.assigns.current_conversation_id == conv_id do
        case Handbeam.ConversationTranscriptStore.list(conv_id) do
          {:ok, entries} ->
            entries
            |> Enum.filter(
              &(&1["content_type"] == "thread_handoff" or
                  get_in(&1, ["origin", "kind"]) == "thread")
            )
            |> Enum.reduce(socket, fn entry, acc ->
              RuntimeProjection.timeline_insert(acc, entry)
            end)

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # Ghostty LiveTerminal.Component sends terminal_ready to parent LiveView.
  # Forward it so the session PTY matches the fitted viewport.
  def handle_info({:terminal_ready, id, cols, rows}, socket) do
    if socket.assigns[:show_terminal] do
      send_update(HandbeamWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_ready, id, cols, rows}
      )
    end

    {:noreply, socket}
  end

  # Forward terminal PubSub events to TerminalPanel component.
  # TerminalPanel is a LiveComponent sharing this LiveView process,
  # so its PubSub subscriptions arrive here.
  def handle_info({:terminal_refresh, ws_id, term_name}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeamWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_refresh, term_name}
      )
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_exited, ws_id, term_name, status}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeamWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_exited, term_name, status}
      )
    end

    {:noreply, socket}
  end

  # Catch-all for unknown pubsub messages
  def handle_info({:ext_ui, %{event: "status", text: text}}, socket) do
    {:noreply, assign(socket, :ext_status_text, text)}
  end

  def handle_info({:ext_ui, %{event: "notify", type: type, text: text}}, socket) do
    {:noreply,
     socket
     |> put_flash(String.to_atom(type), text)
     |> assign(:ext_notification, %{type: type, text: text})}
  end

  def handle_info({:ext_ui, %{event: event, data: data}}, socket) do
    {:noreply, assign(socket, :ext_widget_data, %{event: event, data: data})}
  end

  def handle_info({:start_free_chat_run, conv_id, content, run_opts}, socket) do
    MessageSubmission.start_free_chat_run(socket, conv_id, content, run_opts)
  end

  def handle_info(msg, socket) do
    Logger.debug("[WorkspaceLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Agent event dispatch ──

  # ── Auto-title generation (Qwen Code pattern) ──
  #
  # Start as soon as the user sends the first message. Waiting for :completed
  # leaves the sidebar on "New chat" for the whole agent run.

  # ── Conversation state helpers ──

  defp refresh_conversation_in_sidebar(socket, conv_id),
    do: ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

  defp apply_sidebar_title(socket, conv_id, title, source \\ "auto"),
    do: ConversationSwitching.apply_sidebar_title(socket, conv_id, title, source)

  defp running_for_current_conversation?(socket),
    do: ConversationState.running_for_current_conversation?(socket)

  # ── Tool event helpers ──

  # `@<subagent_type or child id> text` goes to a subagent of this conversation.
  # Anything else, including `@path` mentions, stays a normal message.

  defdelegate attachment_url(attachment), to: Composer
  defdelegate attachment_filename(attachment), to: Composer
  defdelegate image_attachment?(attachment), to: Composer

  defp timeline_entry_id(%{"id" => id}), do: id
  defp timeline_entry_id(%{id: id}), do: id

  defp find_change(timeline, change_id),
    do: HandbeamWeb.ChangeHelper.find_change(timeline, change_id)

  # ── Status helpers ──

  # ── Conversation token helpers ──

  # ── <think> tag stripping ──────────────────────────────────────────

  # ── Model resolution ──

  # Reload workspace models when switching workspaces.
  # Preserves the current selected_model only if still allowed in the new workspace.

  defp load_available_skills(socket) do
    if ConversationState.free_chat?(socket),
      do: assign(socket, :available_skills, []),
      else: Skills.load(socket, ConversationState.current_workspace_path(socket))
  end

  # Resolve a composite model id to a human-readable display name.

  # Same display names stay distinguishable. Cursor stores one name for a base
  # model and its fast variant; the id is what actually differs.
  @doc false

  # ── /model command parser ──

  # ── PubSub subscription ──

  defp subscribe_to_conversation_updates(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbeam.PubSub, "conversation:updated")
    end

    socket
  end

  defp subscribe_workspace_import(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Handbeam.PubSub, "workspace:import")
    end

    socket
  end

  # The native host (if any) owns the picker; a missing host is a no-op.

  defp in_app_ended_flash(task, reason) do
    %{
      body: in_app_ended_message(task, reason),
      navigate: in_app_ended_path(task),
      navigate_with: :patch
    }
  end

  defp in_app_ended_path(%{conversation_id: conv_id, workspace_id: ws_id})
       when is_binary(conv_id) and is_binary(ws_id) and conv_id != "" and ws_id != "" do
    "/w/#{ws_id}/c/#{conv_id}"
  end

  defp in_app_ended_path(_task), do: nil

  defp in_app_ended_message(task, reason) do
    title = task[:title] || gettext("conversation")

    case reason do
      :cancelled -> gettext("Agent stopped in %{title}.", title: title)
      :failed -> gettext("This run ended in %{title}.", title: title)
      _ -> gettext("Agent replied in %{title}.", title: title)
    end
  end

  # ── Conversation construction ──

  defp build_initial_conversations(workspaces, default_ws),
    do: ConversationSwitching.build_initial_conversations(workspaces, default_ws)

  defp initial_conversation_id(conversations_by_ws, ws_id),
    do: ConversationSwitching.initial_conversation_id(conversations_by_ws, ws_id)

  def archived_conversations(workspaces, conversations_by_workspace),
    do: ConversationSwitching.archived_conversations(workspaces, conversations_by_workspace)

  def free_conversations(conversations_by_workspace),
    do: ConversationSwitching.free_conversations(conversations_by_workspace)

  def workspace_conversations(conversations_by_workspace, ws_id, workspaces),
    do:
      ConversationSwitching.workspace_conversations(conversations_by_workspace, ws_id, workspaces)

  def workspace_group_collapsed?(collapsed, id) when is_struct(collapsed, MapSet) do
    MapSet.member?(collapsed, to_string(id))
  end

  def workspace_group_collapsed?(_, _), do: false

  def active_conversation_count(conversations_by_workspace, ws_id, workspaces) do
    conversations_by_workspace
    |> workspace_conversations(ws_id, workspaces)
    |> length()
  end

  def free_conversation_count(conversations_by_workspace) do
    conversations_by_workspace
    |> free_conversations()
    |> length()
  end

  def scoped_conversation_count(conversations_by_workspace, :free, _ws_id, _workspaces) do
    free_conversation_count(conversations_by_workspace)
  end

  def scoped_conversation_count(conversations_by_workspace, _scope, ws_id, workspaces) do
    active_conversation_count(conversations_by_workspace, ws_id, workspaces)
  end

  defp log_workspace_boot(default_ws, workspaces, conversations_by_ws) do
    dev_log(
      "[WorkspaceLive] boot default_workspace=#{inspect(default_ws)} " <>
        "workspaces_file=#{Handbeam.WorkspaceStore.storage_path()} " <>
        "conversation_storage_dir=#{Handbeam.ConversationStore.storage_dir()} " <>
        "conversation_index=#{Handbeam.ConversationStore.index_path()} " <>
        "workspaces=#{inspect(Enum.map(workspaces, &Map.take(&1, ["id", "name", "path", "default"])))} " <>
        "conversation_counts=#{inspect(Map.new(conversations_by_ws, fn {id, convs} -> {id, length(convs)} end))}"
    )
  end

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  # ── Mobile helpers ──

  # ── Helpers for mobile bottom sheets ──

  # ── Mobile sheet helpers ──

  # ── Public helpers for templates (delegated to HandbeamWeb.WorkspaceHelper) ──

  defdelegate status_dot_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_status_icon(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_status_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_border_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate render_tool_status(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_entry_count(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate timeline_summary(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate user_message_nav_items(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_duration(ms), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_bytes(bytes), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_tokens(tokens), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_cache_hit_rate(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate diff_prefix(type), to: HandbeamWeb.WorkspaceHelper
  defdelegate file_value(file, key, default), to: HandbeamWeb.WorkspaceHelper
  defdelegate archived_stream_count(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate browser_install_prompt(entry), to: HandbeamWeb.WorkspaceHelper
  defdelegate preview_card(entry), to: HandbeamWeb.WorkspaceHelper
  defdelegate browser_takeover_prompt(entry), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_entry_name(entry), to: Handbeam.TranscriptEntry, as: :tool_name
  defdelegate tool_entry_status(entry), to: Handbeam.TranscriptEntry, as: :tool_status
  defdelegate tool_entry_duration(entry), to: Handbeam.TranscriptEntry, as: :duration_ms
  defdelegate tool_entry_error(entry), to: Handbeam.TranscriptEntry, as: :error
  defdelegate tool_entry_input_summary(entry), to: Handbeam.TranscriptEntry, as: :input_summary

  defdelegate render_file_preview(path, workspace_root \\ Handbeam.Workspace.root()),
    to: HandbeamWeb.WorkspaceHelper

  # ── Tool approval helpers ──

  defdelegate approval_action_requests(pending), to: Approval, as: :action_requests
  defdelegate format_arguments(arguments), to: Approval

  defp resume_tool_approval(socket, action, remember) when action in [:approve, :deny] do
    conv_id = socket.assigns.current_conversation_id
    pending = socket.assigns.pending_approval

    if is_binary(conv_id) and not is_nil(pending) do
      workspace_root = socket.assigns.workspace_root || Handbeam.Workspace.root()

      case Approval.resume(conv_id, pending, action, remember, workspace_root) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[WorkspaceLive] #{action} tools resume failed: #{inspect(reason)}")
      end

      {:noreply, assign(socket, :pending_approval, nil)}
    else
      {:noreply, socket}
    end
  end

  # ── Conversation stream helpers ──

  defp stream_conversations(socket, conversations_by_ws, workspaces),
    do: ConversationSwitching.stream_conversations(socket, conversations_by_ws, workspaces)

  # ── Settings helpers ──

  defdelegate model_option_label(model, models \\ []), to: ModelSelection
  defdelegate parse_model_command(message), to: ModelSelection
  defdelegate strip_think_tags(buffer, chunk), to: Handbeam.Agent.ThinkingFilter, as: :strip
  defdelegate has_cache_tokens?(status), to: ViewComponents
  defdelegate reasoning_label(level), to: ViewComponents
  defdelegate relative_time(conv), to: ViewComponents

  defdelegate any_sheet_open?(show_workspace, show_model, show_reasoning, show_settings),
    to: ViewComponents

  defdelegate settings_href(workspace_id, conversation_id), to: ViewComponents
  defdelegate permission_label(mode), to: ViewComponents
  def handle_workspace_switch(socket), do: WorkspaceNavigation.after_switch(socket)
end
