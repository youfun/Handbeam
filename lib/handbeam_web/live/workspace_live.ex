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

  alias HandbeamWeb.FileChangeCard
  alias HandbeamWeb.WorkspaceLive.Approval

  import HandbeamWeb.FileChangeCard
  alias HandbeamWeb.WorkspaceLive.Composer
  alias HandbeamWeb.WorkspaceLive.ConversationState
  alias HandbeamWeb.WorkspaceLive.ConversationSwitching
  alias HandbeamWeb.WorkspaceLive.EditorProjection
  alias HandbeamWeb.WorkspaceLive.RuntimeProjection
  alias HandbeamWeb.WorkspaceLive.Skills
  alias HandbeamWeb.WorkspaceLive.ToolProjection
  alias Handbeam.Settings
  alias Handbeam.WorkspaceFiles

  @high_freq_events [:message_delta, :thinking_delta]

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

    _ = Handbeam.Agent.ModelConfig.ensure_config()
    available_models = Handbeam.Agent.ModelConfig.available_models_for_workspace(workspace_root)

    selected_model =
      Handbeam.Agent.ModelConfig.default_model_for_workspace(workspace_root) ||
        (List.first(available_models) && List.first(available_models).id)

    selected_reasoning_level =
      selected_model
      |> model_entry_for(available_models)
      |> Handbeam.Agent.Reasoning.default_level()

    available_reasoning_levels =
      selected_model
      |> model_entry_for(available_models)
      |> Handbeam.Agent.Reasoning.supported_levels()

    # Detect mobile mode from UA on initial render (JS will correct after mount)
    mobile_mode = mobile_mode_from_ua(get_connect_params(socket))

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
        model: model_display_name(selected_model, available_models),
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
      |> sync_conv_state()
      # Add project dialog
      |> assign(:show_add_project, false)
      |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})
      |> assign(:show_file_browser, false)
      |> assign(:file_browser_path, nil)
      |> assign(:sandbox_workspace?, sandbox_workspace?())
      |> subscribe_workspace_import()
      |> assign(:terminal_available?, Handbeam.Host.terminal?())
      |> assign(:show_terminal, false)
      |> assign(:right_panel_view, :files)
      |> assign(:workspace_tree, %{})
      |> assign(:expanded_workspace_dirs, MapSet.new())
      |> assign(:workspace_tree_error, nil)
      |> load_workspace_tree("")
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
      |> reload_workspace_counts()
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
      |> load_permission_mode_into_socket()
      |> subscribe_to_conversation_updates()
      |> subscribe_to_session()
      |> subscribe_to_runtime_tasks()
      |> restore_active_session_snapshot()
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
      |> load_effective_settings()
      |> apply_effective_model_ai_settings()

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
          |> enter_free_chat()
          |> subscribe_to_session()
          |> restore_active_session_snapshot()
          |> close_mobile_sheets()
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
          |> handle_workspace_switch()
          |> subscribe_to_session()
          |> restore_active_session_snapshot()
          |> close_mobile_sheets()

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
    socket =
      socket
      |> maybe_assign_submitted_model(params)
      |> maybe_assign_submitted_reasoning(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", params = %{"message" => message}, socket) do
    message = String.trim(message || "")
    socket = maybe_assign_submitted_model(socket, params)
    socket = maybe_assign_submitted_reasoning(socket, params)

    # Check for /model command
    {maybe_command, remaining, model} = parse_model_command(message)

    socket =
      if maybe_command do
        socket
        |> assign(:selected_model, model)
        |> sync_reasoning_for_model(model)
        |> update_status(%{model: model_display_name(model, socket.assigns.available_models)})
      else
        socket
      end

    # If /model command with no trailing message, stop here
    message = if maybe_command and is_nil(remaining), do: "", else: remaining || message

    socket = assign(socket, :composer_error, nil)

    if dm = subagent_dm(socket, message) do
      send_subagent_dm(socket, dm)
    else
      send_conversation_message(socket, message)
    end
  end

  @impl true
  def handle_event("steer_message", params, socket) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> maybe_assign_submitted_model(params)
      |> maybe_assign_submitted_reasoning(params)
      |> assign(:composer_error, nil)

    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      send_or_queue_current(socket, message, :steer)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("queue_message", params, socket) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> maybe_assign_submitted_model(params)
      |> maybe_assign_submitted_reasoning(params)
      |> assign(:composer_error, nil)

    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      send_or_queue_current(socket, message, :follow_up)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_pending", %{"id" => id}, socket) do
    conv_id = socket.assigns.current_conversation_id
    item = Map.get(socket.assigns.pending_messages, id)

    case Handbeam.Agent.Coordinator.delete_pending_message(conv_id, id) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :pending_messages,
           Handbeam.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> restore_pending_draft(item)
         |> sync_conv_state(reload?: true)
         |> assign(:composer_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(
           :pending_messages,
           Handbeam.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> sync_conv_state(reload?: true)
         |> assign(:composer_error, gettext("Already inserted; cannot undo."))}

      {:error, _reason} ->
        {:noreply, assign(socket, :composer_error, gettext("Could not undo that message."))}
    end
  end

  @impl true
  def handle_event("resend_pending", %{"id" => id}, socket) do
    item = Map.get(socket.assigns.pending_messages, id)

    cond do
      is_nil(item) or item[:status] != :undelivered ->
        {:noreply, socket}

      true ->
        resend_pending_item(socket, id, item)
    end
  end

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
  def handle_event("stop_run", _params, socket) do
    conv_id = socket.assigns.current_conversation_id

    result =
      if is_binary(conv_id) do
        Handbeam.Agent.Coordinator.cancel(conv_id)
      else
        {:error, :not_running}
      end

    case result do
      :ok ->
        {:noreply, mark_run_cancelled(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] stop_run could not cancel run: #{inspect(reason)}")
        {:noreply, mark_run_cancelled(socket)}
    end
  end

  def handle_event("approve_all_tools", params, socket) do
    resume_tool_approval(socket, :approve, Approval.remember_scope(params))
  end

  def handle_event("deny_all_tools", params, socket) do
    resume_tool_approval(socket, :deny, Approval.remember_scope(params))
  end

  @impl true
  def handle_event("select_model", params, socket) do
    model = params["model"] || params["value"]

    socket =
      socket
      |> assign(:selected_model, model)
      |> sync_reasoning_for_model(model)
      |> update_status(%{model: model_display_name(model, socket.assigns.available_models)})
      |> sync_conv_to()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_reasoning", %{"reasoning" => level}, socket) do
    selected =
      if level in socket.assigns.available_reasoning_levels do
        level
      else
        socket.assigns.selected_reasoning_level
      end

    {:noreply,
     socket
     |> assign(:selected_reasoning_level, selected)
     |> sync_conv_to()}
  end

  @impl true
  def handle_event("refresh_models", _params, socket) do
    {:noreply, reload_workspace_models(socket)}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    socket =
      ConversationState.select_file(
        socket,
        path,
        current_workspace_path(socket),
        conversation_state_opts()
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_workspace_file", %{"path" => relative_path}, socket) do
    case WorkspaceFiles.resolve(current_workspace_path(socket), relative_path, :file) do
      {:ok, path} ->
        socket =
          ConversationState.select_file(
            socket,
            path,
            current_workspace_path(socket),
            conversation_state_opts()
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_workspace_directory", %{"path" => relative_path}, socket) do
    expanded = socket.assigns.expanded_workspace_dirs

    if MapSet.member?(expanded, relative_path) do
      {:noreply, assign(socket, :expanded_workspace_dirs, MapSet.delete(expanded, relative_path))}
    else
      {:noreply,
       socket
       |> load_workspace_tree(relative_path)
       |> update(:expanded_workspace_dirs, &MapSet.put(&1, relative_path))}
    end
  end

  @impl true
  def handle_event("select_right_panel_view", %{"view" => view}, socket)
      when view in ["changes", "files"] do
    {:noreply,
     socket
     |> assign(:right_panel_view, String.to_existing_atom(view))
     |> assign(:right_panel_collapsed, false)
     |> assign(:show_terminal, false)}
  end

  def handle_event("select_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, show_terminal_panel(socket)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "files"}, socket) do
    {:noreply,
     socket
     |> assign(:mobile_right_panel_open, true)
     |> assign(:right_panel_view, :files)
     |> assign(:right_panel_collapsed, false)
     |> assign(:show_terminal, false)}
  end

  def handle_event("select_mobile_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, show_terminal_panel(socket, true)}
  end

  def handle_event("close_mobile_right_panel", _params, socket) do
    {:noreply, assign(socket, :mobile_right_panel_open, false)}
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
    {:noreply, mark_revert_confirm(socket, change_id)}
  end

  @impl true
  def handle_event("cancel_revert_change", _params, socket) do
    {:noreply, mark_revert_confirm(socket, nil)}
  end

  @impl true
  def handle_event("revert_change", %{"change_id" => change_id}, socket) do
    with %{} = change <- find_change(socket.assigns.timeline, change_id),
         {:not_running, false} <- {:not_running, running_for_current_conversation?(socket)} do
      result = Handbeam.ChangeReverter.revert(change, current_workspace_path(socket))

      {:noreply,
       EditorProjection.apply_revert_result(
         socket,
         change,
         result,
         current_workspace_path(socket)
       )}
    else
      {:not_running, true} ->
        {:noreply,
         mark_revert_confirm(
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
    {:noreply, open_preview_display(socket, preview_id, :overlay)}
  end

  @impl true
  def handle_event("open_preview_external", %{"id" => preview_id}, socket) do
    {:noreply, open_preview_display(socket, preview_id, :external)}
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
    {:noreply, show_terminal_panel(socket)}
  end

  # ── Workspace / Project dialog ──

  @impl true
  def handle_event("open_add_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_project, true)
     |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})
     |> assign(:show_file_browser, false)}
  end

  @impl true
  def handle_event("cancel_add_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_project, false)
     |> assign(:show_file_browser, false)
     |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})}
  end

  @impl true
  def handle_event("update_add_path", %{"value" => path}, socket) do
    form = Map.put(socket.assigns.add_project_form, "path", path)
    {:noreply, assign(socket, :add_project_form, Map.put(form, "error", nil))}
  end

  @impl true
  def handle_event("update_add_name", %{"value" => name}, socket) do
    form = Map.put(socket.assigns.add_project_form, "name", name)
    {:noreply, assign(socket, :add_project_form, Map.put(form, "error", nil))}
  end

  @impl true
  def handle_event("confirm_add_project", _params, socket) do
    if socket.assigns.sandbox_workspace? and
         String.trim(socket.assigns.add_project_form["path"] || "") == "" do
      request_sandbox_directory_picker()
      {:noreply, socket}
    else
      confirm_add_project(socket)
    end
  end

  def handle_event("browse_folder", _params, socket) do
    if socket.assigns.sandbox_workspace? do
      request_sandbox_directory_picker()
      {:noreply, socket}
    else
      form = socket.assigns.add_project_form
      current = Map.get(form, "path", "")

      {:noreply,
       socket
       |> assign(:show_file_browser, true)
       |> assign(
         :file_browser_path,
         if(current != "" and File.dir?(current), do: current, else: nil)
       )}
    end
  end

  @impl true
  def handle_event("select_workspace", %{"id" => ws_id}, socket) do
    socket = expand_workspace_group(socket, ws_id)
    {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws_id)

    socket =
      socket
      |> handle_workspace_switch()
      |> subscribe_to_session()
      |> restore_active_session_snapshot()
      |> close_mobile_sheets()

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
        |> handle_workspace_switch()
        |> subscribe_to_session()
        |> restore_active_session_snapshot()
        |> close_mobile_sheets()

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
        |> sync_conv_state(reload?: true)
        |> subscribe_to_session()
        |> restore_active_session_snapshot()
        |> close_mobile_sheets()

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
             |> maybe_patch_page_title(conv_id, meta["title"])
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
        conversation_state_opts()
      )

    socket =
      if next_conv_id do
        socket = subscribe_to_session(socket)
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
  def handle_event("toggle_workspace_group", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, toggle_workspace_group(socket, id)}
  end

  @impl true
  def handle_event("toggle_workspace_menu", %{"id" => ws_id}, socket) do
    menu_id = if socket.assigns.workspace_menu_id == ws_id, do: nil, else: ws_id
    {:noreply, assign(socket, :workspace_menu_id, menu_id)}
  end

  def handle_event("close_workspace_menu", _params, socket) do
    {:noreply, assign(socket, :workspace_menu_id, nil)}
  end

  @impl true
  def handle_event("open_remove_workspace", %{"id" => ws_id}, socket) do
    case Handbeam.WorkspaceStore.get(ws_id) do
      {:ok, %{"default" => true}} ->
        {:noreply, assign(socket, :workspace_menu_id, nil)}

      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workspace_menu_id, nil)
         |> assign(:remove_workspace, %{id: ws["id"], name: ws["name"]})}

      {:error, :not_found} ->
        {:noreply, assign(socket, :workspace_menu_id, nil)}
    end
  end

  def handle_event("cancel_remove_workspace", _params, socket) do
    {:noreply, assign(socket, :remove_workspace, nil)}
  end

  @impl true
  def handle_event("confirm_remove_workspace", _params, socket) do
    case socket.assigns.remove_workspace do
      %{id: ws_id} ->
        case ConversationSwitching.remove_workspace(socket, ws_id) do
          {:ok, socket, _removed} ->
            socket =
              if socket.assigns.current_workspace_id == ws_id do
                switch_away_from_removed_workspace(socket)
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
      ConversationSwitching.new_conversation(socket, ws_id, conversation_switching_opts())

    socket =
      socket
      |> expand_workspace_group(ws_id)
      |> subscribe_to_session()

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  @impl true
  def handle_event("new_free_conversation", _params, socket) do
    {socket, conv_id} =
      ConversationSwitching.new_free_conversation(socket, conversation_switching_opts())

    socket =
      socket
      |> expand_workspace_group("free")
      |> enter_free_chat()
      |> subscribe_to_session()
      |> close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
  end

  @impl true
  def handle_event("select_free_conversation", %{"id" => conv_id}, socket) do
    with {:ok, conv} <- Handbeam.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbeam.ConversationStore.free?(conv) do
      {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

      socket =
        socket
        |> enter_free_chat()
        |> subscribe_to_session()
        |> restore_active_session_snapshot()
        |> close_mobile_sheets()

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
    socket =
      case type do
        "workspace" -> assign(socket, :show_workspace_sheet, true)
        "model" -> assign(socket, :show_model_sheet, true)
        "reasoning" -> assign(socket, :show_reasoning_sheet, true)
        "settings" -> assign(socket, :show_settings_sheet, true)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_sheets", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_workspace_sheet, false)
     |> assign(:show_model_sheet, false)
     |> assign(:show_reasoning_sheet, false)
     |> assign(:show_settings_sheet, false)
     |> assign(:show_permission_menu, false)
     |> assign(:show_file_drawer, false)}
  end

  @impl true
  def handle_event("select_model_from_sheet", %{"model" => model}, socket) do
    socket =
      socket
      |> assign(:selected_model, model)
      |> sync_reasoning_for_model(model)
      |> update_status(%{model: model_display_name(model, socket.assigns.available_models)})
      |> sync_conv_to()
      |> assign(:show_model_sheet, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_reasoning_from_sheet", %{"level" => level}, socket) do
    selected =
      if level in socket.assigns.available_reasoning_levels do
        level
      else
        socket.assigns.selected_reasoning_level
      end

    {:noreply,
     socket
     |> assign(:selected_reasoning_level, selected)
     |> assign(:show_reasoning_sheet, false)
     |> sync_conv_to()}
  end

  @impl true
  def handle_event("toggle_file_drawer", _params, socket) do
    {:noreply, update(socket, :show_file_drawer, &(!&1))}
  end

  @impl true
  def handle_event("toggle_right_panel", _params, socket) do
    collapsed = !socket.assigns.right_panel_collapsed

    {:noreply,
     socket
     |> assign(:right_panel_collapsed, collapsed)
     |> push_event("persist_collapsed", %{collapsed: collapsed})}
  end

  @impl true
  def handle_event("set_right_panel_collapsed", %{"collapsed" => collapsed}, socket) do
    {:noreply, assign(socket, :right_panel_collapsed, collapsed)}
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
     |> refresh_tool_work_projection(group_id)}
  end

  def handle_event("toggle_tool_work", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_permission_menu", _params, socket) do
    {:noreply, update(socket, :show_permission_menu, &(!&1))}
  end

  @impl true
  def handle_event("select_permission_mode", %{"mode" => mode_str}, socket) do
    mode = Handbeam.Permissions.ApprovalMode.parse(mode_str, :auto)
    workspace_root = socket.assigns.workspace_root || Handbeam.Workspace.root()

    case Handbeam.WorkspaceSettings.update_default_mode(workspace_root, mode) do
      :ok ->
        Logger.info("[WorkspaceLive] Updated tool default_mode to #{mode} in #{workspace_root}")

        {:noreply,
         socket
         |> assign(:permission_mode, mode)
         |> assign(:show_permission_menu, false)}

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

  defp confirm_add_project(socket) do
    form = socket.assigns.add_project_form
    path = String.trim(form["path"] || "")
    name = String.trim(form["name"] || "")

    cond do
      path == "" ->
        form = Map.put(form, "error", "请输入项目路径")
        {:noreply, assign(socket, :add_project_form, form)}

      not File.exists?(path) ->
        form = Map.put(form, "error", "目录不存在: #{path}")
        {:noreply, assign(socket, :add_project_form, form)}

      not File.dir?(path) ->
        form = Map.put(form, "error", "路径不是一个目录")
        {:noreply, assign(socket, :add_project_form, form)}

      true ->
        case Handbeam.WorkspaceStore.add(path,
               name: if(name != "", do: name, else: Path.basename(path))
             ) do
          {:ok, new_ws} ->
            workspaces = Handbeam.WorkspaceStore.list()

            socket =
              socket
              |> ConversationSwitching.select_new_workspace_without_conversation(
                new_ws,
                workspaces
              )
              |> assign(:show_add_project, false)
              |> assign(:show_file_browser, false)
              |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})
              |> sync_conv_state()
              |> reload_workspace_models()
              |> reload_workspace_counts()
              |> subscribe_to_session()

            {:noreply, socket}

          {:error, reason} ->
            form = Map.put(form, "error", reason)
            {:noreply, assign(socket, :add_project_form, form)}
        end
    end
  end

  defp switch_away_from_removed_workspace(socket) do
    case Enum.find(socket.assigns.workspaces, & &1["default"]) ||
           List.first(socket.assigns.workspaces) do
      nil ->
        socket

      ws ->
        {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws["id"])

        socket =
          socket
          |> handle_workspace_switch()
          |> subscribe_to_session()
          |> restore_active_session_snapshot()
          |> close_mobile_sheets()

        path =
          if conv_id do
            "/w/#{ws["id"]}/c/#{conv_id}"
          else
            "/"
          end

        push_patch(socket, to: path)
    end
  end

  defp create_conversation_in_workspace(socket, ws_id, opts) do
    {socket, conv_id} =
      ConversationSwitching.new_conversation(socket, ws_id, conversation_switching_opts())

    socket =
      socket
      |> expand_workspace_group(ws_id)
      |> handle_workspace_switch()
      |> subscribe_to_session()

    socket =
      if Keyword.get(opts, :close_sheets?, false) do
        close_mobile_sheets(socket)
      else
        socket
      end

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  # ── Workspace / Conversation switching ──

  def handle_workspace_switch(socket) do
    socket
    |> sync_conv_state(reload?: true)
    |> assign(:workspace_tree, %{})
    |> assign(:expanded_workspace_dirs, MapSet.new())
    |> load_workspace_tree("")
    |> reload_workspace_models()
    |> reload_workspace_counts()
    |> load_available_skills()
    |> load_permission_mode_into_socket()
  end

  defp enter_free_chat(socket) do
    socket
    |> assign(:chat_scope, :free)
    |> assign(:right_panel_collapsed, true)
    |> assign(:show_file_drawer, false)
    |> assign(:mobile_right_panel_open, false)
    |> sync_conv_state(reload?: true)
    |> reload_free_models()
    |> assign(:skill_suggestions, [])
    |> assign(:workspace_tree, %{})
  end

  defp load_workspace_tree(socket, relative_dir) do
    case WorkspaceFiles.list(current_workspace_path(socket), relative_dir, show_hidden: true) do
      {:ok, %{entries: entries}} ->
        socket
        |> update(:workspace_tree, &Map.put(&1, relative_dir, entries))
        |> assign(:workspace_tree_error, nil)

      {:error, reason} ->
        assign(socket, :workspace_tree_error, reason)
    end
  end

  defp show_terminal_panel(socket, mobile? \\ false) do
    if Handbeam.Host.terminal?() do
      open_terminal_panel(socket, mobile?)
    else
      socket
    end
  end

  defp open_terminal_panel(socket, mobile?) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Handbeam.PubSub,
        "terminal:\#{socket.assigns.current_workspace_id}"
      )
    end

    socket
    |> assign(:show_terminal, true)
    |> assign(:right_panel_view, :terminal)
    |> assign(:right_panel_collapsed, false)
    |> assign(:mobile_right_panel_open, mobile? or socket.assigns.mobile_right_panel_open)
  end

  @impl true
  def handle_info({:settings_saved, effective}, socket) do
    Logger.debug("[WorkspaceLive] settings saved, om_enabled=#{effective.om_enabled}")

    {:noreply,
     socket
     |> assign(:show_settings_panel, false)
     |> assign(:effective_settings, effective)
     |> apply_effective_model_ai_settings()}
  end

  def handle_info(:settings_closed, socket) do
    {:noreply, assign(socket, :show_settings_panel, false)}
  end

  # ── Agent events ──

  @impl true
  def handle_info({:file_browser_closed}, socket) do
    {:noreply, assign(socket, :show_file_browser, false)}
  end

  @impl true
  def handle_info({:folder_selected_from_browser, path}, socket) do
    form =
      socket.assigns.add_project_form
      |> Map.put("path", path)
      |> Map.put("error", nil)

    {:noreply,
     socket
     |> assign(:add_project_form, form)
     |> assign(:show_file_browser, false)}
  end

  def handle_info({:workspace_imported, item}, socket) when is_map(item) do
    path = item[:path] || item["path"]
    name = item[:name] || item["name"] || Path.basename(to_string(path || ""))

    cond do
      not is_binary(path) or path == "" ->
        {:noreply, socket}

      not File.dir?(path) ->
        form =
          socket.assigns.add_project_form
          |> Map.put("error", "导入失败：目录不可读")

        {:noreply, assign(socket, :add_project_form, form)}

      true ->
        case Handbeam.WorkspaceStore.add(path, name: name) do
          {:ok, new_ws} ->
            workspaces = Handbeam.WorkspaceStore.list()

            socket =
              socket
              |> ConversationSwitching.select_new_workspace_without_conversation(
                new_ws,
                workspaces
              )
              |> assign(:show_add_project, false)
              |> assign(:show_file_browser, false)
              |> assign(:add_project_form, %{"path" => "", "name" => "", "error" => nil})
              |> sync_conv_state()
              |> reload_workspace_models()
              |> reload_workspace_counts()
              |> subscribe_to_session()

            {:noreply, socket}

          {:error, reason} ->
            form = Map.put(socket.assigns.add_project_form, "error", reason)
            {:noreply, assign(socket, :add_project_form, form)}
        end
    end
  end

  @impl true
  def handle_info({:agent_event, event}, socket) do
    socket = handle_current_agent_event(event, socket)
    {:noreply, socket}
  end

  def handle_info(%Handbeam.PubSub.AgentEvent{} = event, socket) do
    socket = handle_current_agent_event(event, socket)
    {:noreply, socket}
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
      |> maybe_patch_current_page_title(conv_id)

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
     |> maybe_patch_page_title(conv_id, title)}
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
              timeline_insert(acc, entry, persist?: false)
            end)

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # Ghostty LiveTerminal.Component sends terminal_ready to parent LiveView
  def handle_info({:terminal_ready, _id, _cols, _rows}, socket) do
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
    if socket.assigns.current_conversation_id == conv_id do
      start_agent_run_now(socket, conv_id, content, run_opts)
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[WorkspaceLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp handle_current_agent_event(
         %Handbeam.PubSub.AgentEvent{topic: "session:" <> _} = event,
         socket
       ) do
    unless event.kind in @high_freq_events do
      Logger.debug(
        "[WorkspaceLive] received agent event kind=#{inspect(event.kind)} " <>
          "topic=#{event.topic} current=#{session_topic(socket.assigns.current_conversation_id)}"
      )
    end

    if event.topic == session_topic(socket.assigns.current_conversation_id) do
      handle_agent_event(event, socket)
    else
      socket
    end
  end

  defp handle_current_agent_event(%Handbeam.PubSub.AgentEvent{} = event, socket) do
    handle_agent_event(event, socket)
  end

  defp handle_current_agent_event(event, socket), do: handle_agent_event(event, socket)

  # ── Agent event dispatch ──

  defp handle_agent_event(%{kind: :run_start, payload: payload}, socket) do
    Logger.debug(
      "[WorkspaceLive] applying run_start conversation=#{socket.assigns.current_conversation_id}"
    )

    socket
    |> assign(:running, true)
    |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:thinking_active, false)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> update_status(%{
      model: model_display_name(payload[:model], socket.assigns.available_models),
      status: :running,
      input_tokens: 0,
      total_input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      turns: 0
    })
  end

  defp handle_agent_event(%{kind: :turn_start, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      turns = payload_value(payload, :turn, Map.get(socket.assigns.status_info, :turns, 0))

      socket
      |> assign(:running, true)
      |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
      |> assign(:stream_suppressed, false)
      |> update_status(%{status: :running, turns: turns})
    end
  end

  defp handle_agent_event(%{kind: :usage_updated, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      # Runtime usage is cumulative for this run; replace rather than add on replay.
      update_status(socket, payload |> payload_value(:usage, %{}) |> usage_tokens())
    end
  end

  defp handle_agent_event(%{kind: :message_delta, payload: %{chunk: chunk}}, socket) do
    # Logger.debug(
    #   "[WorkspaceLive] agent event message_delta bytes=#{byte_size(chunk)} " <>
    #     "conversation=#{socket.assigns.current_conversation_id}"
    # )

    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed message_delta bytes=#{byte_size(chunk)} " <>
          "conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      update_messages(socket, chunk)
    end
  end

  defp handle_agent_event(%{kind: :thinking_delta}, socket) do
    if socket.assigns.stream_suppressed do
      socket
    else
      assign(socket, :thinking_active, true)
    end
  end

  defp handle_agent_event(%{kind: :tool_start, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed tool_start conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      do_handle_tool_start(payload, socket)
    end
  end

  defp handle_agent_event(%{kind: :tool_end, payload: payload}, socket) do
    if socket.assigns.stream_suppressed do
      Logger.debug(
        "[WorkspaceLive] dropped suppressed tool_end conversation=#{socket.assigns.current_conversation_id}"
      )

      socket
    else
      do_handle_tool_end(payload, socket)
    end
  end

  defp handle_agent_event(%{kind: :tool_approval_requested, payload: payload}, socket) do
    Logger.debug(
      "[WorkspaceLive] tool_approval_requested conversation=#{socket.assigns.current_conversation_id}"
    )

    socket
    |> assign(:pending_approval, payload)
    |> update_status(%{status: :awaiting_approval})
  end

  defp handle_agent_event(%{kind: :candidate_message_injected, payload: payload}, socket) do
    pending =
      Handbeam.Agent.PendingMessages.apply_injected(socket.assigns.pending_messages, payload)

    assign_pending_messages(socket, pending)
  end

  defp handle_agent_event(%{kind: :candidate_message_deleted, payload: payload}, socket) do
    pending =
      Handbeam.Agent.PendingMessages.apply_deleted(socket.assigns.pending_messages, payload)

    assign_pending_messages(socket, pending)
  end

  defp handle_agent_event(%{kind: :run_end, payload: payload}, socket) do
    status_value = payload_value(payload, :status, "completed")

    Logger.debug(
      "[WorkspaceLive] agent event run_end status=#{inspect(status_value)} " <>
        "conversation=#{socket.assigns.current_conversation_id}"
    )

    status = safe_atom(status_value)

    socket =
      if socket.assigns.stream_suppressed and status != :cancelled do
        Logger.debug(
          "[WorkspaceLive] dropped suppressed run_end status=#{inspect(status_value)} " <>
            "conversation=#{socket.assigns.current_conversation_id}"
        )

        socket
      else
        do_handle_run_end(payload, status, socket)
        |> assign(:thinking_active, false)
      end

    # Only clear pending_approval on terminal run_end (not interrupted/awaiting_approval)
    socket =
      if status not in [:interrupted] do
        socket
        |> assign(:pending_approval, nil)
        |> assign_pending_messages(
          Handbeam.Agent.PendingMessages.apply_run_end(socket.assigns.pending_messages, status)
        )
      else
        socket
        |> assign(:running, true)
        |> assign(:running_conversation_id, socket.assigns.current_conversation_id)
      end

    socket
  end

  defp handle_agent_event(_event, socket), do: socket

  defp do_handle_tool_start(payload, socket) do
    %{entry: event, tool_name: tool_name} = ToolProjection.start(payload, &summarize_input/2)

    tools_active = Map.put(socket.assigns.tools_active, tool_name, :running)

    socket
    |> finalize_current_assistant()
    |> assign(:tools_active, tools_active)
    |> assign(:current_assistant_entry_id, nil)
    |> timeline_insert(event, persist?: false)
  end

  defp do_handle_tool_end(payload, socket) do
    {id, tool_name, tool_use_id} = ToolProjection.identity(payload)

    base_entry =
      find_timeline_entry(socket.assigns.timeline, id) ||
        %{
          "id" => id,
          "content_type" => "tool",
          "tool_use_id" => tool_use_id,
          "tool_name" => tool_name,
          "tool_input_summary" => ""
        }

    projection = ToolProjection.finish(payload, base_entry)
    %{entry: entry, status: status, file_path: file_path, diff_lines: diff_lines} = projection
    tools_active = Map.put(socket.assigns.tools_active, tool_name, status)

    updated =
      socket
      |> assign(:tools_active, tools_active)
      |> timeline_insert(entry, persist?: false)
      |> EditorProjection.maybe_add_diff_file(
        file_path,
        diff_lines,
        current_workspace_path(socket)
      )

    if updated.assigns.editor_files != socket.assigns.editor_files,
      do: refresh_loaded_tree_parent(updated, Path.expand(file_path)),
      else: updated
  end

  defp do_handle_run_end(payload, status, socket) do
    turns = payload_value(payload, :turns, 0)
    run_error = payload_value(payload, :error)
    # Runtime already recorded a terminal run. Reload that conversation's
    # totals. Interrupted is not terminal, so keep the in-flight figures.
    usage =
      if status == :interrupted do
        payload |> payload_value(:usage, %{}) |> usage_tokens()
      else
        load_conversation_token_usage(socket.assigns.current_conversation_id)
      end

    socket =
      socket
      |> assign(:conv_tokens, usage)
      |> finalize_current_assistant()
      |> assign(:running, false)
      |> assign(:running_conversation_id, nil)
      |> assign(:stream_suppressed, status == :cancelled)
      |> assign(:tools_active, %{})
      |> assign(:current_assistant_entry_id, nil)
      |> update_status(Map.merge(%{status: status, turns: turns}, usage))
      |> maybe_append_error_message(run_error, persist?: false)

    # If the send path did not name the chat, try again now. A completed run
    # must not be required for the first title.
    maybe_auto_title(socket, status)
  end

  defp mark_run_cancelled(socket) do
    socket
    |> finalize_current_assistant()
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, true)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:pending_approval, nil)
    |> update_status(%{status: :cancelled})
  end

  # ── Auto-title generation (Qwen Code pattern) ──
  #
  # Start as soon as the user sends the first message. Waiting for :completed
  # leaves the sidebar on "New chat" for the whole agent run.

  defp schedule_auto_title(socket, message) when is_binary(message) do
    trigger_auto_title(socket, message)
  end

  defp schedule_auto_title(socket, _message), do: socket

  defp maybe_auto_title(socket, :completed) do
    conversation_id = socket.assigns.current_conversation_id

    timeline =
      conversation_id
      |> load_transcript_entries(socket.assigns.timeline)

    first_user_msg =
      Enum.find_value(timeline, fn entry ->
        if entry["role"] == "user" and not is_nil(entry["content"]) do
          entry["content"]
        end
      end)

    if first_user_msg do
      trigger_auto_title(socket, first_user_msg)
    else
      Logger.debug(
        "[WorkspaceLive] maybe_auto_title skip — no user message found in timeline conv_id=#{conversation_id}"
      )

      socket
    end
  end

  defp maybe_auto_title(socket, _not_completed), do: socket

  defp trigger_auto_title(socket, message) when is_binary(message) do
    conv = current_conv_map(socket)
    title = conv_value(conv, "title", "")
    title_source = conv_value(conv, "title_source", nil)
    conversation_id = socket.assigns.current_conversation_id

    Logger.debug(
      "[WorkspaceLive] maybe_auto_title entry conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
    )

    cond do
      titled?(title, title_source) ->
        Logger.debug(
          "[WorkspaceLive] maybe_auto_title skip — title already set conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
        )

        socket

      String.trim(message) == "" ->
        socket

      true ->
        socket = show_provisional_title(socket, conversation_id, message)

        case resolve_auto_title_model(socket, conv) do
          {:ok, provider_config, selected_model} ->
            provider_config = Map.put(provider_config, :notify_pid, self())

            case Handbeam.ConversationTitleGenerator.maybe_generate(
                   conversation_id,
                   message,
                   provider_config
                 ) do
              {:ok, pid} ->
                Logger.debug(
                  "[WorkspaceLive] Triggered auto-title generation conv_id=#{conversation_id} model=#{inspect(selected_model)} task_pid=#{inspect(pid)}"
                )

              :skip ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate returned :skip conv_id=#{conversation_id}"
                )

              other ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate failed conv_id=#{conversation_id} result=#{inspect(other)}"
                )
            end

            socket

          {:error, reason, selected_model} ->
            Logger.debug(
              "[WorkspaceLive] Skipped model title model=#{inspect(selected_model)} reason=#{inspect(reason)}"
            )

            socket
        end
    end
  end

  defp titled?(title, source) do
    not Handbeam.ConversationTitleGenerator.default_title?(title) and source != "fallback"
  end

  defp show_provisional_title(socket, conversation_id, message) do
    case Handbeam.ConversationTitleGenerator.publish_provisional(conversation_id, message) do
      {:ok, title} ->
        socket
        |> apply_sidebar_title(conversation_id, title, "fallback")
        |> maybe_patch_page_title(conversation_id, title)

      :skip ->
        socket
    end
  end

  # ── Conversation state helpers ──

  defp sync_conv_state(socket, opts \\ []) do
    ConversationState.sync_conv_state(socket, Keyword.merge(conversation_state_opts(), opts))
  end

  defp restore_active_session_snapshot(socket) do
    conv_id = socket.assigns.current_conversation_id

    cond do
      not is_binary(conv_id) ->
        socket

      is_nil(Handbeam.PubSub.Session.whereis(conv_id)) ->
        socket

      true ->
        case Handbeam.PubSub.Session.snapshot(conv_id) do
          %{events: events, meta: meta} ->
            # Verify the run is actually still active: if the agent process
            # is dead (e.g. Session restarted after a crash), don't replay
            # events that would set running=true and show "agent working".
            agent_pid = Map.get(meta, :agent_pid)

            actually_running? =
              Map.get(meta, :running?, false) and
                agent_pid != nil and
                Process.alive?(agent_pid)

            if actually_running? do
              timeline = socket.assigns.timeline
              replay_message_delta? = not timeline_has_assistant_message?(timeline)

              Logger.debug(
                "[WorkspaceLive] restoring active session snapshot conversation=#{conv_id} " <>
                  "events=#{length(events)} replay_message_delta?=#{replay_message_delta?}"
              )

              socket =
                if replay_message_delta? do
                  socket
                else
                  assign(socket, :current_assistant_entry_id, last_assistant_message_id(timeline))
                end

              socket =
                events
                |> Enum.sort_by(& &1.seq)
                |> maybe_skip_message_delta_events(replay_message_delta?)
                |> Enum.reduce(socket, fn event, socket ->
                  handle_current_agent_event(event, socket)
                end)

              pending =
                Handbeam.Agent.PendingMessages.reconcile(
                  socket.assigns.pending_messages || %{},
                  session_pending_messages(conv_id),
                  true,
                  socket.assigns.timeline || []
                )

              assign(socket, :pending_messages, pending)
            else
              socket
            end

          _ ->
            socket
        end
    end
  end

  defp session_pending_messages(conv_id) do
    if Handbeam.PubSub.Session.whereis(conv_id) do
      Handbeam.PubSub.Session.get_pending_messages(conv_id)
    else
      []
    end
  catch
    :exit, _ -> []
  end

  defp maybe_skip_message_delta_events(events, true), do: events

  defp maybe_skip_message_delta_events(events, false) do
    Enum.reject(events, &(&1.kind == :message_delta))
  end

  defp timeline_has_assistant_message?(timeline) do
    Enum.any?(timeline, fn entry ->
      Map.get(entry, "content_type") == "assistant_msg" or
        Map.get(entry, :content_type) == "assistant_msg"
    end)
  end

  defp last_assistant_message_id(timeline) do
    timeline
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      content_type = Map.get(entry, "content_type", Map.get(entry, :content_type))

      if content_type == "assistant_msg" do
        Map.get(entry, "id", Map.get(entry, :id))
      end
    end)
  end

  defp sync_conv_to(socket), do: ConversationState.sync_conv_to(socket)
  defp current_conv_map(socket), do: ConversationState.current_conv_map(socket)

  defp conv_value(conversation, key, default),
    do: ConversationState.conv_value(conversation, key, default)

  defp load_transcript_entries(conversation_id, fallback),
    do: ConversationState.load_transcript_entries(conversation_id, fallback)

  defp load_conversation_token_usage(conv_id),
    do: ConversationState.load_conversation_token_usage(conv_id)

  defp refresh_conversation_in_sidebar(socket, conv_id),
    do: ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

  defp apply_sidebar_title(socket, conv_id, title, source \\ "auto"),
    do: ConversationSwitching.apply_sidebar_title(socket, conv_id, title, source)

  defp running_for_current_conversation?(socket),
    do: ConversationState.running_for_current_conversation?(socket)

  defp conversation_state_opts do
    [
      model_display_name: &model_display_name/2,
      sync_reasoning_for_conversation: &sync_reasoning_for_conversation/3,
      update_status: &maybe_update_status/2,
      load_effective_settings: &load_effective_settings/1
    ]
  end

  defp conversation_switching_opts do
    Keyword.take(conversation_state_opts(), [:model_display_name, :update_status])
    |> Keyword.put(:initialize_model, &initialize_conversation_model/1)
  end

  defp free_chat?(socket), do: socket.assigns[:chat_scope] == :free

  defp current_workspace_path(socket) do
    if free_chat?(socket) do
      nil
    else
      ws_id = socket.assigns.current_workspace_id

      case Handbeam.WorkspaceStore.get(ws_id) do
        {:ok, ws} -> ws["path"]
        {:error, _} -> Handbeam.Workspace.root()
      end
    end
  end

  # ── Tool event helpers ──

  defp summarize_input(input, _tool_name) do
    case input do
      %{file_path: path} when is_binary(path) ->
        Path.basename(path) <> range_suffix(input)

      %{"file_path" => path} when is_binary(path) ->
        Path.basename(path) <> range_suffix(input)

      %{command: cmd} when is_binary(cmd) ->
        String.slice(cmd, 0, 60)

      %{"command" => cmd} when is_binary(cmd) ->
        String.slice(cmd, 0, 60)

      %{content: content} when is_binary(content) ->
        String.slice(content, 0, 60)

      %{"content" => content} when is_binary(content) ->
        String.slice(content, 0, 60)

      %{query: query} when is_binary(query) ->
        String.slice(query, 0, 60)

      %{"query" => query} when is_binary(query) ->
        String.slice(query, 0, 60)

      _ when input == %{} ->
        ""

      _ ->
        input |> inspect() |> String.slice(0, 60)
    end
  end

  defp range_suffix(input) do
    offset = get_offset(input)
    limit = get_limit(input)

    cond do
      is_integer(offset) and offset > 0 and is_integer(limit) ->
        end_line = offset + limit - 1
        ":#{offset}-#{end_line}"

      is_integer(offset) and offset > 0 ->
        ":#{offset}"

      true ->
        ""
    end
  end

  defp get_offset(%{offset: offset}) when is_integer(offset), do: offset
  defp get_offset(%{"offset" => offset}) when is_integer(offset), do: offset
  defp get_offset(_), do: nil

  defp get_limit(%{limit: limit}) when is_integer(limit), do: limit
  defp get_limit(%{"limit" => limit}) when is_integer(limit), do: limit
  defp get_limit(_), do: nil

  defp send_conversation_message(socket, message) do
    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      running_for_current? =
        running_for_current_conversation?(socket) or not is_nil(socket.assigns.pending_approval)

      socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)

      case prepare_outbound_message(socket, message) do
        {:ok, socket, content, attachments} ->
          conv_id = socket.assigns.current_conversation_id

          if running_for_current? do
            queue_running_agent_message(
              socket,
              conv_id,
              content,
              message,
              attachments,
              :steer
            )
          else
            start_new_agent_run(socket, conv_id, content, message, attachments)
          end

        {:error, socket} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # `@<subagent_type or child id> text` goes to a subagent of this conversation.
  # Anything else, including `@path` mentions, stays a normal message.
  defp subagent_dm(socket, message) do
    with conv_id when is_binary(conv_id) <- socket.assigns.current_conversation_id,
         [] <- socket.assigns.pending_attachments,
         false <- has_upload_entries?(socket),
         [_, ref, text] <- Regex.run(~r/\A@([\w.-]+)\s+(\S.*)\z/s, message),
         {:ok, children} <- Handbeam.Agent.Delegation.status(conv_id, :list),
         true <- Enum.any?(children, &(ref in [&1.child_conversation_id, &1.subagent_type])) do
      %{conversation_id: conv_id, ref: ref, text: text}
    else
      _ -> nil
    end
  end

  defp send_subagent_dm(socket, %{conversation_id: conv_id, ref: ref, text: text}) do
    case Handbeam.Agent.Delegation.message(conv_id, ref, text, source: :web) do
      {:ok, %{delivery: delivery}} ->
        note =
          if delivery == :steer,
            do: gettext("Sent to subagent %{ref}.", ref: ref),
            else: gettext("Subagent %{ref} is answering a follow-up.", ref: ref)

        {:noreply,
         socket
         |> assign(:input_value, "")
         |> put_flash(:info, note)
         |> push_event("user-message-sent", %{})}

      {:error, reason} ->
        reason = if is_binary(reason), do: reason, else: inspect(reason)
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  defp send_or_queue_current(socket, message, deliver_as) do
    running_for_current? =
      running_for_current_conversation?(socket) or not is_nil(socket.assigns.pending_approval)

    socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)

    case prepare_outbound_message(socket, message) do
      {:ok, socket, content, attachments} ->
        conv_id = socket.assigns.current_conversation_id

        if running_for_current? do
          queue_running_agent_message(
            socket,
            conv_id,
            content,
            message,
            attachments,
            deliver_as
          )
        else
          start_new_agent_run(socket, conv_id, content, message, attachments)
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp restore_pending_draft(socket, item) when is_map(item) do
    Composer.restore_draft(socket, item)
  end

  defp restore_pending_draft(socket, _), do: socket

  defp resend_pending_item(socket, id, item) do
    content_text = if is_binary(item[:content]), do: item[:content], else: ""
    attachments = List.wrap(item[:attachments])
    conv_id = socket.assigns.current_conversation_id

    if String.trim(content_text) == "" and attachments == [] do
      {:noreply, socket}
    else
      socket =
        assign_pending_messages(
          socket,
          Handbeam.Agent.PendingMessages.put_status(
            socket.assigns.pending_messages,
            id,
            :resending
          )
        )

      workspace_path = current_workspace_path(socket)

      case Handbeam.Attachments.MessageBuilder.build(
             content_text,
             attachments,
             Composer.build_opts(socket, workspace_path)
           ) do
        {:ok, content, persistable} ->
          msg_id = unique_id("msg-user")
          content = put_inbound_message_id(content, msg_id)
          deliver_as = item[:deliver_as] || :steer

          case add_message_to_current_conversation(socket, conv_id, content,
                 deliver_as: deliver_as,
                 message_id: msg_id,
                 attachments: persistable
               ) do
            {:ok, ack} ->
              finish_resend_pending(
                socket,
                id,
                msg_id,
                content_text,
                persistable,
                ack,
                deliver_as
              )

            {:error, reason} ->
              {:noreply,
               socket
               |> assign_pending_messages(
                 Handbeam.Agent.PendingMessages.put_status(
                   socket.assigns.pending_messages,
                   id,
                   :undelivered
                 )
               )
               |> assign(:composer_error, resend_error(reason))}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> assign_pending_messages(
             Handbeam.Agent.PendingMessages.put_status(
               socket.assigns.pending_messages,
               id,
               :undelivered
             )
           )
           |> assign(:composer_error, outbound_error(reason))}
      end
    end
  end

  defp finish_resend_pending(socket, old_id, msg_id, content_text, attachments, ack, deliver_as) do
    conv_id = socket.assigns.current_conversation_id
    draft = socket.assigns.input_value
    composer_atts = socket.assigns.pending_attachments

    delete_ok? =
      case drop_transcript_entry(conv_id, old_id) do
        :ok -> true
        {:ok, _} -> true
        _ -> false
      end

    pending =
      socket.assigns.pending_messages
      |> Handbeam.Agent.PendingMessages.drop(old_id)

    pending =
      if ack[:action] == :enqueued do
        Handbeam.Agent.PendingMessages.put_queued(pending, msg_id, deliver_as, %{
          content: content_text,
          attachments: attachments
        })
      else
        pending
      end

    socket =
      socket
      |> assign_pending_messages(pending)
      |> sync_conv_state(reload?: true)
      |> assign(:input_value, draft)
      |> assign(:pending_attachments, composer_atts)
      |> assign(
        :composer_error,
        if(delete_ok?,
          do: nil,
          else: gettext("Resent, but the previous copy could not be removed from history.")
        )
      )

    socket =
      if ack[:action] == :started do
        socket
        |> assign(:running, true)
        |> assign(:running_conversation_id, conv_id)
      else
        socket
      end

    {:noreply, socket}
  end

  defp assign_pending_messages(socket, pending) do
    Composer.assign_pending(socket, pending)
  end

  defp drop_transcript_entry(conversation_id, id),
    do: Composer.drop_transcript_entry(conversation_id, id)

  defp put_inbound_message_id(content, id), do: Composer.put_message_id(content, id)

  defp queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    msg_id = unique_id("msg-user")
    content = put_inbound_message_id(content, msg_id)

    case add_message_to_current_conversation(socket, conv_id, content,
           deliver_as: deliver_as,
           message_id: msg_id,
           attachments: attachments
         ) do
      {:ok, %{action: :enqueued}} ->
        pending =
          Handbeam.Agent.PendingMessages.put_queued(
            socket.assigns.pending_messages,
            msg_id,
            deliver_as,
            %{content: message, attachments: attachments}
          )

        socket =
          socket
          |> assign(:input_value, "")
          |> append_user_message(message, attachments, msg_id)
          |> assign(:pending_attachments, [])
          |> assign(:pending_messages, pending)
          |> push_event("user-message-sent", %{})

        {:noreply, socket}

      {:ok, %{action: :started}} ->
        {:noreply,
         socket
         |> assign(:input_value, "")
         |> append_user_message(message, attachments, msg_id)
         |> assign(:pending_attachments, [])
         |> assign(:running, true)
         |> assign(:running_conversation_id, conv_id)
         |> push_event("user-message-sent", %{})}

      {:error, :queue_full} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :queue_full")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, :sealed} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :sealed")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: #{inspect(reason)}")
        {:noreply, mark_stale_running_message_rejected(socket)}
    end
  end

  defp add_message_to_current_conversation(socket, conv_id, content, opts) do
    {selected_model, selected_reasoning_level} = effective_model_and_reasoning(socket)
    workspace_path = current_workspace_path(socket)

    with {:ok, provider_config, model_id} <-
           resolve_selected_model(workspace_path, selected_model) do
      model_entry = model_entry_for(selected_model, socket.assigns.available_models)

      provider_config =
        Handbeam.Agent.Reasoning.apply_provider_options(
          provider_config,
          model_entry,
          selected_reasoning_level
        )

      msg_id = Keyword.get(opts, :message_id)

      om_opts = om_from_effective(socket.assigns.effective_settings)

      Handbeam.Agent.Coordinator.add_message(
        conv_id,
        content,
        run_opts(socket,
          provider_config: provider_config,
          model: model_id,
          reasoning_level: selected_reasoning_level,
          workspace_path: workspace_path,
          deliver_as: Keyword.get(opts, :deliver_as, :steer),
          transcript_id: msg_id,
          message_id: msg_id,
          inbound_id: msg_id,
          attachments: Keyword.get(opts, :attachments, []),
          om: Keyword.get(om_opts, :om)
        )
      )
    end
  end

  defp run_opts(socket, extra) do
    base =
      if free_chat?(socket) do
        [
          chat_scope: :free,
          tools: tools_for(socket),
          workspace_id: nil,
          workspace_path: nil,
          mcp: false,
          source: :live_view,
          streaming: true
        ]
      else
        [
          chat_scope: :workspace,
          tools: tools_for(socket),
          workspace_id: socket.assigns.current_workspace_id,
          workspace_path: current_workspace_path(socket),
          source: :live_view,
          streaming: true
        ]
      end

    Keyword.merge(base, extra)
  end

  defp mark_stale_running_message_rejected(socket) do
    socket
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> sync_conv_state(reload?: true)
    |> restore_active_session_snapshot()
    |> assign(
      :composer_error,
      "The previous run is no longer accepting input. Send again to start a new run in this conversation."
    )
  end

  defp start_new_agent_run(socket, conv_id, content, message, attachments) do
    {selected_model, selected_reasoning_level} = effective_model_and_reasoning(socket)
    workspace_path = current_workspace_path(socket)

    case resolve_selected_model(workspace_path, selected_model) do
      {:ok, provider_config, model_id} ->
        model_entry = model_entry_for(selected_model, socket.assigns.available_models)

        provider_config =
          Handbeam.Agent.Reasoning.apply_provider_options(
            provider_config,
            model_entry,
            selected_reasoning_level
          )

        msg_id = unique_id("msg-user")
        content = put_inbound_message_id(content, msg_id)

        socket =
          socket
          |> assign(:input_value, "")
          |> assign(:running, true)
          |> assign(:running_conversation_id, conv_id)
          |> assign(:stream_suppressed, false)
          |> assign(:tools_active, %{})
          |> assign(:timeline, socket.assigns.timeline)
          |> stream(:timeline, socket.assigns.timeline, reset: true)
          |> assign(:thinking_content, "")
          |> assign(:think_buffer, "")
          |> assign(:current_assistant_entry_id, nil)
          |> append_user_message(message, attachments, msg_id)
          |> assign(:pending_attachments, [])
          |> schedule_auto_title(message)
          |> update_status(%{
            status: :running,
            input_tokens: 0,
            total_input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            turns: 0
          })
          |> subscribe_to_session()
          |> push_event("user-message-sent", %{})

        om_opts = om_from_effective(socket.assigns.effective_settings)

        run_opts =
          run_opts(socket,
            provider_config: provider_config,
            model: model_id,
            reasoning_level: selected_reasoning_level,
            workspace_path: workspace_path,
            transcript_id: msg_id,
            message_id: msg_id,
            inbound_id: msg_id,
            attachments: attachments,
            om: Keyword.get(om_opts, :om)
          )

        if free_chat?(socket) do
          send(self(), {:start_free_chat_run, conv_id, content, run_opts})
          {:noreply, socket}
        else
          start_agent_run_now(socket, conv_id, content, run_opts)
        end

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  defp start_agent_run_now(socket, conv_id, content, run_opts) do
    case Handbeam.Agent.Coordinator.add_message(conv_id, content, run_opts) do
      {:ok, _ack} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Failed to start agent run: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:running, false)
         |> assign(:running_conversation_id, nil)
         |> assign(:stream_suppressed, true)
         |> assign(:composer_error, "Message not delivered: #{inspect(reason)}")}
    end
  end

  defp ensure_current_conversation(socket) do
    socket
    |> ConversationSwitching.ensure_current_conversation(conversation_state_opts())
    |> subscribe_to_session()
  end

  defp append_user_message(socket, message, attachments, id) do
    entry = %{
      "id" => id || unique_id("msg-user"),
      "content_type" => "user_msg",
      "role" => "user",
      "content" => message,
      "attachments" => attachments
    }

    timeline_insert(socket, entry, persist?: false)
  end

  defp prepare_outbound_message(socket, message) do
    Composer.prepare(socket, message, current_workspace_path(socket))
  end

  defp has_upload_entries?(socket), do: Composer.has_upload_entries?(socket)
  defp outbound_error(reason), do: Composer.outbound_error(reason)
  defp resend_error(reason), do: Composer.resend_error(reason)
  defdelegate attachment_url(attachment), to: Composer
  defdelegate attachment_filename(attachment), to: Composer
  defdelegate image_attachment?(attachment), to: Composer

  defp timeline_insert(socket, entry, opts) do
    persist? = Keyword.get(opts, :persist?, true)
    socket = RuntimeProjection.timeline_insert(socket, entry)

    if persist?, do: sync_conv_to(socket), else: socket
  end

  defp refresh_tool_work_projection(socket, group_id),
    do: RuntimeProjection.refresh_tool_work(socket, group_id)

  defp mark_revert_confirm(socket, change_id),
    do: RuntimeProjection.mark_revert_confirm(socket, change_id)

  defp find_timeline_entry(timeline, id), do: RuntimeProjection.find_entry(timeline, id)

  defp timeline_entry_id(%{"id" => id}), do: id
  defp timeline_entry_id(%{id: id}), do: id

  defp finalize_current_assistant(socket), do: RuntimeProjection.finalize_assistant(socket)

  defp assistant_message_final?(entry, running, current_assistant_entry_id),
    do: RuntimeProjection.assistant_final?(entry, running, current_assistant_entry_id)

  defp assistant_message_streaming?(entry, running, current_assistant_entry_id) do
    running && Map.get(entry, "id") == current_assistant_entry_id &&
      !truthy?(Map.get(entry, "final"))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp unique_id(prefix), do: RuntimeProjection.unique_id(prefix)

  defp find_change(timeline, change_id),
    do: HandbeamWeb.ChangeHelper.find_change(timeline, change_id)

  defp refresh_loaded_tree_parent(socket, abs_path) do
    relative = Path.relative_to(abs_path, current_workspace_path(socket))

    parent =
      case Path.dirname(relative) do
        "." -> ""
        directory -> directory
      end

    if Map.has_key?(socket.assigns.workspace_tree, parent) do
      load_workspace_tree(socket, parent)
    else
      socket
    end
  end

  defp maybe_append_error_message(socket, error, opts)
  defp maybe_append_error_message(socket, nil, _opts), do: socket

  defp maybe_append_error_message(socket, error, opts) do
    msg = "Run error: #{error}"

    entry = %{
      "id" => unique_id("msg-system"),
      "content_type" => "system_msg",
      "role" => "system",
      "content" => msg
    }

    timeline_insert(socket, entry, opts)
  end

  # ── Status helpers ──

  defp update_status(socket, overrides), do: RuntimeProjection.update_status(socket, overrides)

  defp maybe_update_status(socket, overrides),
    do: RuntimeProjection.maybe_update_status(socket, overrides)

  defp usage_tokens(usage), do: RuntimeProjection.usage_tokens(usage)

  # ── Conversation token helpers ──

  @doc """
  Returns true if the status_info map has any cache token activity.
  Used to conditionally show the cache token display in the status bar.
  """
  def has_cache_tokens?(%{cache_read_tokens: read, cache_write_tokens: write})
      when is_number(read) and is_number(write) do
    read > 0 or write > 0
  end

  def has_cache_tokens?(_), do: false

  defp payload_value(payload, key, default \\ nil),
    do: RuntimeProjection.payload_value(payload, key, default)

  defp safe_atom(value), do: RuntimeProjection.safe_status(value)
  defp update_messages(socket, chunk), do: RuntimeProjection.update_messages(socket, chunk)

  # ── <think> tag stripping ──────────────────────────────────────────

  @doc """
  Strip `<think>...</think>` tags from streaming text chunks.

  Returns `{thinking_text, clean_text, new_buffer}` where:
  - `thinking_text` — text extracted from inside think tags (for separate display)
  - `clean_text` — text with think tags removed (for main display)
  - `new_buffer` — accumulated partial state for next chunk.
    `"<"` prefix means we were inside a think tag; `""` or other means outside.
  """
  def strip_think_tags(buffer, chunk) do
    Handbeam.Agent.ThinkingFilter.strip(buffer, chunk)
  end

  defp default_tools, do: Handbeam.Agent.default_tools()

  defp tools_for(socket) do
    if free_chat?(socket), do: Handbeam.Agent.free_chat_tools(), else: default_tools()
  end

  # ── Model resolution ──

  defp resolve_selected_model(_workspace_path, nil),
    do: {:error, "Configure models before sending"}

  defp resolve_selected_model(workspace_path, selected_model) do
    if is_binary(workspace_path) and workspace_path != "" do
      case Handbeam.Agent.ModelConfig.resolve_model_for_workspace(workspace_path, selected_model) do
        {:ok, provider_config, model_id} -> {:ok, provider_config, model_id}
        {:error, reason} -> {:error, reason}
      end
    else
      resolve_global_model(selected_model)
    end
  end

  defp resolve_global_model(selected_model) do
    model_entry =
      Enum.find(Handbeam.Agent.ModelConfig.all_global_models(), &(&1.id == selected_model))

    if model_entry do
      case Handbeam.Agent.ModelConfig.provider_config_for(
             File.cwd!(),
             model_entry.provider_id,
             model_entry.model_id
           ) do
        {:ok, provider_config} -> {:ok, provider_config, model_entry.model_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Model #{selected_model} is not available"}
    end
  end

  defp resolve_auto_title_model(socket, _conv) do
    workspace_path = current_workspace_path(socket)

    # Use the resolved model from socket assigns (which may have fallen back
    # to an available model), not the raw conversation store value.
    model_id = socket.assigns[:selected_model]

    case resolve_selected_model(workspace_path, model_id) do
      {:ok, provider_config, _resolved_id} ->
        {:ok, provider_config, model_id}

      {:error, reason} ->
        {:error, reason, model_id}
    end
  end

  defp maybe_assign_submitted_model(socket, %{"model" => model}) when is_binary(model) do
    if Enum.any?(socket.assigns.available_models, &(&1.id == model)) do
      socket
      |> assign(:selected_model, model)
      |> sync_reasoning_for_model(model)
    else
      socket
    end
  end

  defp maybe_assign_submitted_model(socket, _params), do: socket

  defp maybe_assign_submitted_reasoning(socket, %{"reasoning" => reasoning})
       when is_binary(reasoning) do
    if reasoning in socket.assigns.available_reasoning_levels do
      assign(socket, :selected_reasoning_level, reasoning)
    else
      socket
    end
  end

  defp maybe_assign_submitted_reasoning(socket, _params), do: socket

  # Reload workspace models when switching workspaces.
  # Preserves the current selected_model only if still allowed in the new workspace.
  defp reload_free_models(socket) do
    available = Handbeam.Agent.ModelConfig.all_global_models()
    settings = Handbeam.Settings.global_model_ai()

    selected =
      cond do
        settings.default_model && Enum.any?(available, &(&1.id == settings.default_model)) ->
          settings.default_model

        socket.assigns.selected_model &&
            Enum.any?(available, &(&1.id == socket.assigns.selected_model)) ->
          socket.assigns.selected_model

        true ->
          available |> List.first() |> then(&if(&1, do: &1.id))
      end

    socket
    |> assign(:available_models, available)
    |> assign(:selected_model, selected)
    |> assign(:effective_settings, settings)
    |> sync_reasoning_for_model(selected)
    |> update_status(%{model: model_display_name(selected, available)})
  end

  defp reload_workspace_models(socket) do
    if free_chat?(socket) do
      reload_free_models(socket)
    else
      reload_workspace_models_for_path(socket)
    end
  end

  defp reload_workspace_models_for_path(socket) do
    workspace_root =
      case Handbeam.WorkspaceStore.get(socket.assigns.current_workspace_id) do
        {:ok, ws} -> ws["path"]
        {:error, _} -> Handbeam.Workspace.root()
      end

    available = Handbeam.Agent.ModelConfig.available_models_for_workspace(workspace_root)

    current_model = socket.assigns.selected_model

    selected =
      if current_model && Enum.any?(available, &(&1.id == current_model)) do
        current_model
      else
        nil
      end

    socket
    |> assign(:available_models, available)
    |> assign(:selected_model, selected)
    |> sync_reasoning_for_model(selected)
    |> update_status(%{model: model_display_name(selected, available)})
    |> maybe_sync_selected_model_to_conversation()
  end

  defp reload_workspace_counts(socket) do
    if free_chat?(socket) do
      assign(socket, :mcp_count, 0) |> assign(:skills_count, 0)
    else
      reload_workspace_counts_for_path(socket)
    end
  end

  defp reload_workspace_counts_for_path(socket) do
    workspace_root = current_workspace_path(socket)

    mcp_count =
      case Handbeam.MCP.ConfigLoader.load(project: workspace_root) do
        {:ok, config} -> map_size(config.servers)
      end

    skills_count = length(Handbeam.Skills.Loader.load(workspace: workspace_root).skills)

    socket
    |> assign(:mcp_count, mcp_count)
    |> assign(:skills_count, skills_count)
  end

  defp load_available_skills(socket) do
    if free_chat?(socket),
      do: assign(socket, :available_skills, []),
      else: Skills.load(socket, current_workspace_path(socket))
  end

  defp sync_reasoning_for_model(socket, model_id) do
    model_entry = model_entry_for(model_id, socket.assigns.available_models)
    levels = Handbeam.Agent.Reasoning.supported_levels(model_entry)
    current = Map.get(socket.assigns, :selected_reasoning_level)

    selected =
      if current in levels do
        current
      else
        Handbeam.Agent.Reasoning.default_level(model_entry)
      end

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  defp sync_reasoning_for_conversation(socket, conv, model_id) do
    model_entry = model_entry_for(model_id, Map.get(socket.assigns, :available_models, []))
    levels = Handbeam.Agent.Reasoning.supported_levels(model_entry)
    stored = conv_value(conv, "selected_reasoning_level", nil)

    selected =
      if stored in levels do
        stored
      else
        Handbeam.Agent.Reasoning.default_level(model_entry)
      end

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  defp maybe_sync_selected_model_to_conversation(socket) do
    conv = current_conv_map(socket)

    if conv_value(conv, "selected_model", nil) == socket.assigns.selected_model do
      socket
    else
      sync_conv_to(socket)
    end
  end

  defp model_entry_for(nil, _available), do: %{}

  defp model_entry_for(composite_id, available) do
    Enum.find(available, &(&1.id == composite_id || &1.model_id == composite_id)) || %{}
  end

  # Resolve a composite model id to a human-readable display name.
  defp model_display_name(nil, _available), do: "None"

  defp model_display_name(composite_id, available) do
    case Enum.find(available, &(&1.id == composite_id || &1.model_id == composite_id)) do
      nil ->
        composite_id

      entry ->
        siblings = Enum.filter(available, &(&1.provider_id == entry.provider_id))
        "#{provider_display_name(entry.provider_id)} / #{model_option_label(entry, siblings)}"
    end
  end

  defp models_by_provider(models) do
    models
    |> Enum.group_by(& &1.provider_id)
    |> Enum.sort_by(fn {provider_id, _models} -> provider_display_name(provider_id) end)
  end

  defp provider_display_name(nil), do: "Unknown"
  defp provider_display_name(provider_id), do: provider_id

  # Same display names stay distinguishable. Cursor stores one name for a base
  # model and its fast variant; the id is what actually differs.
  @doc false
  def model_option_label(model, models \\ []) do
    name = label_name(model)

    case distinguishing_label(model, name, models) do
      nil -> name
      suffix -> "#{name} #{suffix}"
    end
  end

  defp label_name(model) do
    cond do
      is_binary(model.name) and model.name != "" -> model.name
      is_binary(model.model_id) and model.model_id != "" -> model.model_id
      true -> model.id
    end
  end

  defp distinguishing_label(model, name, models) do
    id = model_identity(model)

    collisions =
      Enum.filter(models, fn other ->
        label_name(other) == name and model_identity(other) != id
      end)

    if collisions == [] do
      nil
    else
      tokens = id_tokens(id)

      extra =
        Enum.reject(tokens, fn token ->
          Enum.all?(collisions, &(token in id_tokens(model_identity(&1))))
        end)

      cond do
        extra == [] -> nil
        extra == tokens -> "(#{id_tail(id)})"
        true -> Enum.map_join(extra, " ", &humanize_id_token/1)
      end
    end
  end

  defp model_identity(model) do
    if is_binary(model.model_id) and model.model_id != "", do: model.model_id, else: model.id
  end

  defp id_tail(id) do
    id |> to_string() |> String.split("/") |> List.last()
  end

  defp id_tokens(id) do
    id_tail(id)
    |> String.split("-")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp humanize_id_token("fast"), do: "Fast"
  defp humanize_id_token("max"), do: "Max"
  defp humanize_id_token("thinking"), do: "Thinking"
  defp humanize_id_token("1m"), do: "1M"
  defp humanize_id_token(token), do: String.capitalize(token)

  defp model_empty_message(workspace_root) do
    case Handbeam.Agent.ModelConfig.global_config_status() do
      :ok ->
        case Handbeam.Agent.ModelConfig.load_workspace_policy(workspace_root) do
          {:ok, _policy} -> "No allowed models configured for this workspace"
          {:error, _reason} -> "Workspace model policy is invalid"
          :unrestricted -> "Configure models before sending"
        end

      {:error, _reason} ->
        "Configure models before sending"
    end
  end

  # ── /model command parser ──

  def parse_model_command(message) when is_binary(message) do
    case String.split(message, ~r/\s+/, parts: 3) do
      ["/model", model_id] ->
        {true, nil, model_id}

      ["/model", model_id, rest] ->
        {true, rest, model_id}

      _ ->
        {false, nil, nil}
    end
  end

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

  defp sandbox_workspace? do
    Handbeam.Host.configured?() and not Handbeam.Host.shell?()
  end

  # The native host (if any) owns the picker; a missing host is a no-op.
  defp request_sandbox_directory_picker do
    _ = Handbeam.Host.request_directory_picker(%{purpose: :add_workspace})
    :ok
  end

  defp subscribe_to_extension_ui(socket) do
    if connected?(socket) do
      conv_id = socket.assigns.current_conversation_id
      topic = Handbeam.Extension.UI.topic(conv_id)
      previous_topic = Map.get(socket.assigns, :subscribed_ext_ui_topic)

      if previous_topic && previous_topic != topic do
        Phoenix.PubSub.unsubscribe(Handbeam.PubSub, previous_topic)
      end

      if previous_topic != topic do
        Phoenix.PubSub.subscribe(Handbeam.PubSub, topic)
      end

      assign(socket, :subscribed_ext_ui_topic, topic)
    else
      socket
    end
  end

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

  defp subscribe_to_runtime_tasks(socket) do
    if connected?(socket) do
      Handbeam.Runtime.TaskTracker.subscribe()
      Handbeam.Runtime.TaskTracker.viewing(self(), socket.assigns.current_conversation_id)
      assign(socket, :runtime_tasks, Handbeam.Runtime.TaskTracker.snapshot())
    else
      assign(socket, :runtime_tasks, %{running_count: 0, waiting_count: 0, tasks: []})
    end
  end

  defp subscribe_to_session(socket) do
    if connected?(socket) do
      Handbeam.Runtime.TaskTracker.viewing(self(), socket.assigns.current_conversation_id)
      conv_id = socket.assigns.current_conversation_id
      topic = session_topic(conv_id)
      previous_topic = Map.get(socket.assigns, :subscribed_session_topic)

      if previous_topic && previous_topic != topic do
        Phoenix.PubSub.unsubscribe(Handbeam.PubSub, previous_topic)
      end

      if previous_topic != topic do
        Phoenix.PubSub.subscribe(Handbeam.PubSub, topic)
      end

      socket
      |> assign(:subscribed_session_topic, topic)
      |> subscribe_to_extension_ui()
    else
      socket
    end
  end

  defp session_topic(conv_id), do: "session:#{conv_id}"

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

  defp toggle_workspace_group(socket, id) do
    id = to_string(id)

    update(socket, :collapsed_workspace_ids, fn collapsed ->
      collapsed = collapsed || MapSet.new()

      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)
    end)
  end

  defp expand_workspace_group(socket, id) do
    id = to_string(id)

    update(socket, :collapsed_workspace_ids, fn collapsed ->
      MapSet.delete(collapsed || MapSet.new(), id)
    end)
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

  defp open_preview_display(socket, preview_id, client) do
    conversation_id = socket.assigns.current_conversation_id

    case Handbeam.Preview.fetch_open(preview_id) do
      {:ok, record} ->
        if record.conversation_id != conversation_id do
          put_flash(socket, :error, "preview belongs to another conversation")
        else
          url = Handbeam.Preview.shell_url(preview_id, HandbeamWeb.Endpoint.url())

          meta = %{
            conversation_id: conversation_id,
            preview_id: preview_id,
            url: url,
            client: client,
            bind_listen?: false
          }

          case Handbeam.NativeDisplay.command(
                 %{
                   op: if(client == :external, do: :open_external, else: :show),
                   owner: :preview,
                   id: preview_id,
                   url: url,
                   conversation_id: conversation_id,
                   generation: 1
                 },
                 []
               ) do
            {:error, :not_configured} ->
              _ = Handbeam.Browser.Display.show(:preview, preview_id, meta)

              if client == :external do
                push_event(socket, "open_preview_url", %{url: url, bind_listen: false})
              else
                socket
              end

            {:ok, _} ->
              _ = Handbeam.Browser.Display.show(:preview, preview_id, meta)
              socket

            :ok ->
              _ = Handbeam.Browser.Display.show(:preview, preview_id, meta)
              socket

            {:error, reason} ->
              put_flash(socket, :error, "preview display failed: #{inspect(reason)}")
          end
        end

      {:error, :closed} ->
        put_flash(socket, :error, "preview is closed")

      {:error, :not_found} ->
        put_flash(socket, :error, "preview not found")
    end
  end

  defp mobile_mode_from_ua(nil), do: false

  defp mobile_mode_from_ua(%{"uastring" => ua}) when is_binary(ua) do
    mobile_pattern = ~r/(iPhone|iPad|iPod|Android|Mobile|webOS|BlackBerry|Windows Phone)/i
    String.match?(ua, mobile_pattern)
  end

  defp mobile_mode_from_ua(_), do: false

  # ── Helpers for mobile bottom sheets ──

  def any_sheet_open?(show_workspace, show_model, show_reasoning, show_settings) do
    show_workspace or show_model or show_reasoning or show_settings
  end

  attr :entries, :map, required: true
  attr :expanded, :any, required: true
  attr :active_file, :string, default: nil
  attr :workspace_root, :string, required: true
  attr :parent, :string, default: ""
  attr :depth, :integer, default: 0

  def workspace_tree(assigns) do
    ~H"""
    <ul class="workspace-file-tree" role={if(@depth == 0, do: "tree", else: "group")}>
      <li :for={entry <- Map.get(@entries, @parent, [])} role="treeitem">
        <button
          :if={entry.kind == :directory}
          type="button"
          class="workspace-file-row directory"
          style={"--tree-depth: #{@depth}"}
          phx-click="toggle_workspace_directory"
          phx-value-path={entry.relative_path}
          aria-expanded={to_string(MapSet.member?(@expanded, entry.relative_path))}
          title={entry.relative_path}
        >
          <span class="workspace-tree-chevron" aria-hidden="true">
            {if MapSet.member?(@expanded, entry.relative_path), do: "⌄", else: "›"}
          </span>
          <span class="workspace-tree-icon" aria-hidden="true">▱</span>
          <span class="truncate">{entry.name}</span>
        </button>
        <.workspace_tree
          :if={entry.kind == :directory && MapSet.member?(@expanded, entry.relative_path)}
          entries={@entries}
          expanded={@expanded}
          active_file={@active_file}
          workspace_root={@workspace_root}
          parent={entry.relative_path}
          depth={@depth + 1}
        />
        <button
          :if={entry.kind == :file}
          type="button"
          class={[
            "workspace-file-row file",
            if(@active_file == Path.join(@workspace_root, entry.relative_path),
              do: "active",
              else: ""
            )
          ]}
          style={"--tree-depth: #{@depth}"}
          phx-click="select_workspace_file"
          phx-value-path={entry.relative_path}
          title={entry.relative_path}
        >
          <span class="workspace-tree-chevron" aria-hidden="true"></span>
          <span class="workspace-tree-icon file" aria-hidden="true">▧</span>
          <span class="truncate">{entry.name}</span>
        </button>
        <div
          :if={entry.kind == :symlink}
          class="workspace-file-row symlink"
          style={"--tree-depth: #{@depth}"}
          title={gettext("Symlinks are not opened from the workspace tree")}
        >
          <span class="workspace-tree-chevron" aria-hidden="true"></span>
          <span class="workspace-tree-icon" aria-hidden="true">↗</span>
          <span class="truncate">{entry.name}</span>
        </div>
      </li>
    </ul>
    """
  end

  def reasoning_label(level) do
    case level do
      "off" -> gettext("Off")
      "minimal" -> gettext("Minimal")
      "low" -> gettext("Low")
      "medium" -> gettext("Medium")
      "high" -> gettext("High")
      "xhigh" -> gettext("X-High")
      _ -> level
    end
  end

  def relative_time(conv) do
    case Map.get(conv, :updated_at) || Map.get(conv, "updated_at") || Map.get(conv, :created_at) ||
           Map.get(conv, "created_at") do
      nil ->
        ""

      dt_str ->
        case DateTime.from_iso8601(dt_str) do
          {:ok, dt, _} ->
            diff = DateTime.diff(DateTime.utc_now(), dt, :second)

            cond do
              diff < 60 -> "刚刚"
              diff < 3600 -> "#{div(diff, 60)}分钟前"
              diff < 86400 -> "#{div(diff, 3600)}小时前"
              true -> dt_str |> String.slice(0, 10)
            end

          _ ->
            ""
        end
    end
  end

  # ── Mobile sheet helpers ──
  defp close_mobile_sheets(socket) do
    socket
    |> assign(:show_workspace_sheet, false)
    |> assign(:show_model_sheet, false)
    |> assign(:show_reasoning_sheet, false)
    |> assign(:show_settings_sheet, false)
    |> assign(:show_permission_menu, false)
    |> assign(:show_file_drawer, false)
    |> assign(:conversation_menu_id, nil)
  end

  defp maybe_patch_page_title(socket, conv_id, title) do
    if socket.assigns.current_conversation_id == conv_id and is_binary(title) and title != "" do
      assign(socket, :page_title, title)
    else
      socket
    end
  end

  defp maybe_patch_current_page_title(socket, conv_id) do
    title =
      socket.assigns.conversations_by_workspace
      |> Map.values()
      |> List.flatten()
      |> Enum.find_value(fn conv ->
        if ConversationState.conversation_id(conv) == conv_id do
          ConversationState.conv_value(conv, "title", nil)
        end
      end)

    maybe_patch_page_title(socket, conv_id, title)
  end

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

  defp load_permission_mode_into_socket(socket) do
    permission_mode =
      if free_chat?(socket) do
        :deny
      else
        load_permission_mode(socket.assigns.workspace_root || Handbeam.Workspace.root())
      end

    assign(socket, :permission_mode, permission_mode)
  end

  defp load_permission_mode(workspace_root) do
    case Handbeam.WorkspaceSettings.load(workspace_root) do
      {:ok, settings} ->
        tools = Map.get(settings, "tools", %{})
        tools = if is_map(tools), do: tools, else: %{}
        Handbeam.Permissions.ApprovalMode.parse(Map.get(tools, "default_mode"), :auto)

      {:error, _} ->
        :auto
    end
  end

  def settings_href(workspace_id, conversation_id) do
    query = %{}
    query = if workspace_id, do: Map.put(query, :workspace_id, workspace_id), else: query
    query = if conversation_id, do: Map.put(query, :conversation_id, conversation_id), else: query
    ~p"/settings?#{query}"
  end

  def permission_label(:auto), do: "完整存取"
  def permission_label(:prompt), do: "安全模式"
  def permission_label(:deny), do: "只读"
  def permission_label(_), do: "完整存取"

  # ── Settings helpers ──

  defp load_effective_settings(socket) do
    if free_chat?(socket) do
      assign(socket, :effective_settings, Handbeam.Settings.global_model_ai())
    else
      load_workspace_effective_settings(socket)
    end
  end

  defp load_workspace_effective_settings(socket) do
    workspace_path = socket.assigns.workspace_root || Handbeam.Workspace.root()

    if is_nil(workspace_path) or workspace_path == "" do
      Logger.warning(
        "[WorkspaceLive] load_effective_settings: workspace_path is nil/empty, skipping"
      )

      assign(socket, :effective_settings, Handbeam.Settings.ModelAISettings.defaults())
    else
      case Settings.fetch_effective_model_ai(workspace_path) do
        {:ok, effective} ->
          assign(socket, :effective_settings, effective)

        {:error, reason} ->
          Logger.error("[WorkspaceLive] load_effective_settings failed: #{inspect(reason)}")
          assign(socket, :effective_settings, Handbeam.Settings.ModelAISettings.defaults())
      end
    end
  end

  defp initialize_conversation_model(socket) do
    if free_chat?(socket) do
      reload_free_models(socket)
    else
      initialize_workspace_conversation_model(socket)
    end
  end

  defp initialize_workspace_conversation_model(socket) do
    available =
      Handbeam.Agent.ModelConfig.available_models_for_workspace(socket.assigns.workspace_root)

    socket
    |> assign(:available_models, available)
    |> load_effective_settings()
    |> apply_effective_model_ai_settings()
  end

  defp apply_effective_model_ai_settings(socket) do
    effective = socket.assigns.effective_settings
    available = socket.assigns.available_models

    selected_model =
      cond do
        effective && effective.default_model &&
            Enum.any?(available, &(&1.id == effective.default_model)) ->
          effective.default_model

        socket.assigns.selected_model &&
            Enum.any?(available, &(&1.id == socket.assigns.selected_model)) ->
          socket.assigns.selected_model

        true ->
          socket.assigns.selected_model
      end

    socket = assign(socket, :selected_model, selected_model)

    socket =
      if effective && effective.reasoning do
        levels =
          Handbeam.Agent.Reasoning.supported_levels(model_entry_for(selected_model, available))

        if effective.reasoning in levels do
          socket
          |> assign(:available_reasoning_levels, levels)
          |> assign(:selected_reasoning_level, effective.reasoning)
        else
          sync_reasoning_for_model(socket, selected_model)
        end
      else
        sync_reasoning_for_model(socket, selected_model)
      end

    update_status(socket, %{model: model_display_name(selected_model, available)})
  end

  defp effective_model_and_reasoning(socket) do
    effective = socket.assigns[:effective_settings]

    model =
      cond do
        socket.assigns.selected_model ->
          socket.assigns.selected_model

        effective && effective.default_model ->
          effective.default_model

        true ->
          nil
      end

    # Conversation picker wins. Global settings only fill in when this
    # conversation has not chosen a level yet. Amp cannot switch mid-thread;
    # Handbeam can, so the composer value must reach the next turn.
    reasoning =
      cond do
        is_binary(socket.assigns[:selected_reasoning_level]) and
            socket.assigns.selected_reasoning_level != "" ->
          socket.assigns.selected_reasoning_level

        effective && effective.reasoning ->
          effective.reasoning

        true ->
          Handbeam.Settings.ModelAISettings.defaults().reasoning
      end

    {model, reasoning}
  end

  defp om_from_effective(nil), do: []

  defp om_from_effective(effective) do
    opts = Handbeam.Settings.ModelAISettings.to_runtime_opts(effective)
    [om: Keyword.get(opts, :om, %{enabled: false})]
  end
end
