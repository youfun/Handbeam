defmodule HandbeamWeb.WorkspaceLive.SidebarComponents do
  @moduledoc false

  use HandbeamWeb, :html

  import HandbeamWeb.WorkspaceLive.ViewComponents

  attr :chat_scope, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :terminal_available?, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspaces, :any, required: true

  def mobile_header(assigns) do
    ~H"""
    <div class="mobile-header-v2">
      <button
        phx-click="open_sheet"
        phx-value-type="workspace"
        class="mobile-header-workspace-btn"
      >
        <div class="mobile-header-title">
          <img src={~p"/images/logo.svg"} class="brand-mark" width="18" height="18" alt="" />
          <span class="mobile-brand">Handbeam</span>
          <span class="mobile-workspace truncate">
            {if(@chat_scope == :free, do: gettext("对话"), else: @workspace_label)}
          </span>
        </div>
        <span
          id="mobile-workspace-count"
          class="mobile-workspace-count"
          title={gettext("会话数量")}
        >
          {scoped_conversation_count(
            @conversations_by_workspace,
            @chat_scope,
            @current_workspace_id,
            @workspaces
          )}
        </span>
        <svg
          class="mobile-chevron"
          width="10"
          height="10"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="3"
          aria-hidden="true"
        >
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>
      <div class="mobile-header-actions">
        <button
          :if={@chat_scope != :free}
          id="mobile-open-files"
          phx-click="select_mobile_right_panel_view"
          phx-value-view="files"
          class="mobile-header-panel-btn"
          aria-label={gettext("Files")}
          title={gettext("Files")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 6h6l2 2h10v10H3z" />
          </svg>
        </button>
        <button
          :if={@terminal_available?}
          id="mobile-open-terminal"
          phx-click="select_mobile_right_panel_view"
          phx-value-view="terminal"
          class="mobile-header-panel-btn"
          aria-label={gettext("Terminal")}
          title={gettext("Terminal")}
        >
          <span aria-hidden="true">›_</span>
        </button>
        <button
          phx-click="open_sheet"
          phx-value-type="settings"
          class="mobile-header-info-btn"
          aria-label={gettext("Conversation info")}
          title={gettext("Conversation info")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="10" />
            <path d="M12 16v-4" />
            <path d="M12 8h.01" />
          </svg>
        </button>
        <.link
          id="mobile-open-settings"
          navigate={settings_href(@current_workspace_id, @current_conversation_id)}
          class="mobile-header-settings-btn"
          title={gettext("Settings")}
          aria-label={gettext("Settings")}
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0 1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </.link>
      </div>
    </div>
    """
  end

  attr :chat_scope, :any, required: true
  attr :collapsed_workspace_ids, :any, required: true
  attr :conversation_menu_id, :any, required: true
  attr :conversations_by_workspace, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :show_archive, :any, required: true
  attr :streams, :any, required: true
  attr :workspace_menu_id, :any, required: true
  attr :workspaces, :any, required: true

  def projects_sidebar(assigns) do
    ~H"""
    <div
      id="activity-bar"
      class="w-[220px] flex-shrink-0 border-r bg-surface flex flex-col workspace-panel projects-panel"
    >
      <div class="projects-panel-header">
        <h2 class="projects-panel-title">
          <img src={~p"/images/logo.svg"} class="brand-mark" width="16" height="16" alt="" />
          <span>{gettext("专案")}</span>
        </h2>
        <button
          phx-click="open_add_project"
          class="text-xs text-tertiary hover:text-primary transition-colors leading-none"
          title={gettext("添加项目")}
        >
          +
        </button>
      </div>
      <div class="flex-1 overflow-y-auto">
        <!-- Workspace headers (outside stream, fixed) -->
        <div
          :for={ws <- @workspaces}
          id={"workspace-group-#{ws["id"]}"}
          class={[
            "workspace-group",
            workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) && "is-collapsed"
          ]}
        >
          <div class={[
            "workspace-title-row",
            @current_workspace_id == ws["id"] && @chat_scope != :free && "is-active"
          ]}>
            <button
              phx-click="select_workspace"
              phx-value-id={ws["id"]}
              class={[
                "workspace-header min-w-0 text-left px-2 py-1.5 text-xs flex items-center gap-1.5 transition-colors",
                if(@current_workspace_id == ws["id"],
                  do: "workspace-header-active",
                  else: "hover:bg-surface-hover"
                )
              ]}
            >
              <span class="workspace-icon" aria-hidden="true">
                <svg
                  width="12"
                  height="12"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
                </svg>
              </span>
              <span class="truncate flex-1">{ws["name"]}</span>
              <span :if={ws["default"]} class="text-tertiary text-[0.6rem]">default</span>
            </button>
            <div class="workspace-row-actions">
              <button
                phx-click="new_conversation_in_workspace"
                phx-value-ws_id={ws["id"]}
                class="workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors"
                title={gettext("在此工作区新建对话")}
              >
                <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                  <path
                    d="M6 1v10M1 6h10"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                  />
                </svg>
              </button>
              <div :if={!ws["default"]} class="workspace-menu">
                <button
                  type="button"
                  phx-click="toggle_workspace_menu"
                  phx-value-id={ws["id"]}
                  id={"workspace-menu-#{ws["id"]}"}
                  class={["workspace-action", @workspace_menu_id == ws["id"] && "is-open"]}
                  title={gettext("更多操作")}
                  aria-label={gettext("更多操作")}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@workspace_menu_id == ws["id"])}
                >
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 12 12"
                    fill="currentColor"
                    aria-hidden="true"
                  >
                    <circle cx="2.25" cy="6" r="1" />
                    <circle cx="6" cy="6" r="1" />
                    <circle cx="9.75" cy="6" r="1" />
                  </svg>
                </button>
                <div
                  :if={@workspace_menu_id == ws["id"]}
                  id={"workspace-menu-panel-#{ws["id"]}"}
                  class="workspace-menu-panel"
                  role="menu"
                  phx-click-away="close_workspace_menu"
                >
                  <button
                    type="button"
                    role="menuitem"
                    phx-click="open_remove_workspace"
                    phx-value-id={ws["id"]}
                    id={"workspace-action-remove-#{ws["id"]}"}
                    class="workspace-menu-item danger"
                  >
                    <span>{gettext("移除工作区")}</span>
                  </button>
                </div>
              </div>
            </div>
            <button
              type="button"
              id={"workspace-toggle-#{ws["id"]}"}
              phx-click="toggle_workspace_group"
              phx-value-id={ws["id"]}
              class="workspace-count-toggle"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]))
              }
              aria-controls={"workspace-conversations-#{ws["id"]}"}
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              aria-label={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
            >
              <span
                id={"workspace-count-#{ws["id"]}"}
                class="workspace-conv-count"
                title={gettext("会话数量")}
              >
                {active_conversation_count(@conversations_by_workspace, ws["id"], @workspaces)}
              </span>
              <svg
                class={[
                  "workspace-chevron-icon",
                  workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"]) && "is-collapsed"
                ]}
                width="10"
                height="10"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>

          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, ws["id"])}
            id={"workspace-conversations-#{ws["id"]}"}
            class="conversations-list"
          >
            <div
              :for={
                conv <-
                  workspace_conversations(@conversations_by_workspace, ws["id"], @workspaces)
              }
              :if={!conv.archived}
              id={"conversation-#{conv.id}"}
              class="conversation-row"
            >
              <button
                phx-click="select_conversation"
                phx-value-id={conv.id}
                phx-value-ws_id={conv.workspace_id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-tertiary"
                  )
                ]}
              >
                <span class={[
                  "conversation-dot",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "conversation-dot-active",
                    else: ""
                  )
                ]}></span>
                <span class="truncate flex-1">{conv.title}</span>
              </button>
              <div class="conversation-menu">
                <button
                  type="button"
                  phx-click="toggle_conversation_menu"
                  phx-value-id={conv.id}
                  id={"conversation-menu-#{conv.workspace_id}-#{conv.id}"}
                  class={[
                    "conversation-action",
                    @conversation_menu_id == conv.id && "is-open"
                  ]}
                  title={gettext("更多操作")}
                  aria-label={gettext("更多操作")}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@conversation_menu_id == conv.id)}
                >
                  <span class="sr-only">{gettext("更多操作")}</span>
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 12 12"
                    fill="currentColor"
                    aria-hidden="true"
                  >
                    <circle cx="2.25" cy="6" r="1" />
                    <circle cx="6" cy="6" r="1" />
                    <circle cx="9.75" cy="6" r="1" />
                  </svg>
                </button>
                <div
                  :if={@conversation_menu_id == conv.id}
                  id={"conversation-menu-panel-#{conv.id}"}
                  class="conversation-menu-panel"
                  role="menu"
                  phx-click-away="close_conversation_menu"
                >
                  <button
                    type="button"
                    role="menuitem"
                    phx-click="open_rename_conversation"
                    phx-value-id={conv.id}
                    phx-value-ws_id={conv.workspace_id}
                    id={"conversation-action-rename-#{conv.workspace_id}-#{conv.id}"}
                    class="conversation-menu-item"
                  >
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
                      <path
                        d="M7.2 2.1 9.9 4.8 4.4 10.3 1.5 10.5l.2-2.9L7.2 2.1Z"
                        stroke="currentColor"
                        stroke-width="1.1"
                        stroke-linejoin="round"
                      />
                      <path
                        d="M6.4 2.9 9.1 5.6"
                        stroke="currentColor"
                        stroke-width="1.1"
                        stroke-linecap="round"
                      />
                    </svg>
                    <span>{gettext("重命名")}</span>
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    id={"conversation-action-copy-id-#{conv.workspace_id}-#{conv.id}"}
                    class="conversation-menu-item"
                    phx-hook="CopyText"
                    data-copy={conv.id}
                    title={gettext("复制会话 ID，用于线程通讯")}
                  >
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
                      <rect
                        x="4.25"
                        y="3.25"
                        width="5.5"
                        height="6.5"
                        rx="0.75"
                        stroke="currentColor"
                        stroke-width="1.1"
                      />
                      <path
                        d="M3.25 8.75H2.75A.75.75 0 0 1 2 8V2.75A.75.75 0 0 1 2.75 2H8a.75.75 0 0 1 .75.75V3.25"
                        stroke="currentColor"
                        stroke-width="1.1"
                        stroke-linecap="round"
                      />
                    </svg>
                    <span class="copy-idle">{gettext("复制 ID")}</span>
                    <span class="copy-done">{gettext("已复制")}</span>
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    phx-click="archive_conversation"
                    phx-value-id={conv.id}
                    phx-value-ws_id={conv.workspace_id}
                    id={"conversation-action-archive-#{conv.workspace_id}-#{conv.id}"}
                    class="conversation-menu-item danger"
                  >
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
                      <path
                        d="M2 3.5h8M4.5 3.5V2.75a.75.75 0 0 1 .75-.75h1.5a.75.75 0 0 1 .75.75V3.5M3 3.5l.5 6.75a.75.75 0 0 0 .75.75h3.5a.75.75 0 0 0 .75-.75L9 3.5"
                        stroke="currentColor"
                        stroke-width="1.1"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                      />
                    </svg>
                    <span>{gettext("归档")}</span>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div
          id="free-chats"
          class={[
            "workspace-group mt-2 border-t pt-2",
            workspace_group_collapsed?(@collapsed_workspace_ids, "free") && "is-collapsed"
          ]}
        >
          <div class={[
            "workspace-title-row",
            @chat_scope == :free && "is-active"
          ]}>
            <div class="workspace-header min-w-0 text-left px-2 py-1.5 text-xs flex items-center gap-1.5">
              <span class="truncate flex-1">{gettext("对话")}</span>
            </div>
            <button
              id="new-free-conversation"
              phx-click="new_free_conversation"
              class="workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors"
              title={gettext("新建自由对话")}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path
                  d="M6 1v10M1 6h10"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                />
              </svg>
            </button>
            <button
              type="button"
              id="free-workspace-toggle"
              phx-click="toggle_workspace_group"
              phx-value-id="free"
              class="workspace-count-toggle"
              aria-expanded={
                to_string(not workspace_group_collapsed?(@collapsed_workspace_ids, "free"))
              }
              aria-controls="free-conversations"
              title={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "free"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
              aria-label={
                if(workspace_group_collapsed?(@collapsed_workspace_ids, "free"),
                  do: gettext("展开"),
                  else: gettext("收起")
                )
              }
            >
              <span id="free-workspace-count" class="workspace-conv-count" title={gettext("会话数量")}>
                {free_conversation_count(@conversations_by_workspace)}
              </span>
              <svg
                class={[
                  "workspace-chevron-icon",
                  workspace_group_collapsed?(@collapsed_workspace_ids, "free") && "is-collapsed"
                ]}
                width="10"
                height="10"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
          </div>
          <div
            :if={not workspace_group_collapsed?(@collapsed_workspace_ids, "free")}
            id="free-conversations"
            class="conversations-list"
          >
            <div
              :for={conv <- free_conversations(@conversations_by_workspace)}
              id={"free-conversation-#{conv.id}"}
              class="conversation-row"
            >
              <button
                phx-click="select_free_conversation"
                phx-value-id={conv.id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left pl-6 pr-1 py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(@current_conversation_id == conv.id and @chat_scope == :free,
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-secondary"
                  )
                ]}
              >
                <span class="truncate flex-1">{conv.title}</span>
              </button>
            </div>
          </div>
        </div>

        <!-- Archived conversations -->
        <div class="workspace-group mt-2 border-t pt-2">
          <button
            phx-click="toggle_archive"
            class="w-full text-left px-3 py-1.5 flex items-center gap-1.5 text-xs text-tertiary hover:bg-surface-hover transition-colors rounded"
          >
            <span class={["workspace-chevron", if(@show_archive, do: "expanded", else: "")]}>
              {if(@show_archive, do: "▾", else: "▸")}
            </span>
            <span>{gettext("已存档")}</span>
            <span class="ml-auto tabular-nums text-[0.6rem] lowercase">
              {archived_stream_count(@streams.conversations)}
            </span>
          </button>

          <div :if={@show_archive} class="conversations-list">
            <div
              :for={{dom_id, conv} <- @streams.conversations}
              :if={conv.archived}
              id={dom_id}
              class="conversation-row archived"
            >
              <button
                phx-click="select_archived_conversation"
                phx-value-ws={conv.workspace_id}
                phx-value-id={conv.id}
                class={[
                  "conversation-item flex-1 min-w-0 text-left pl-6 pr-1 py-1.5 text-xs transition-colors flex items-center gap-1.5",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "conversation-item-active",
                    else: "hover:bg-surface-hover text-tertiary"
                  )
                ]}
              >
                <span class={[
                  "conversation-dot archived",
                  if(
                    @current_conversation_id == conv.id and
                      @current_workspace_id == conv.workspace_id,
                    do: "conversation-dot-active",
                    else: ""
                  )
                ]}></span>
                <span class="truncate flex-1">{conv.title}</span>
                <span class="conversation-badge">{conv.workspace_name}</span>
              </button>
              <button
                phx-click="unarchive_conversation"
                phx-value-id={conv.id}
                class="conversation-action restore"
                title={gettext("恢复")}
              >
                <svg width="11" height="11" viewBox="0 0 12 12" fill="none">
                  <path
                    d="M3 6.5a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5a.5.5 0 0 1-.5-.5z"
                    fill="currentColor"
                  /><path
                    d="M6 3.5a.5.5 0 0 1 .5.5v5a.5.5 0 0 1-1 0V4a.5.5 0 0 1 .5-.5z"
                    fill="currentColor"
                  />
                </svg>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

end
