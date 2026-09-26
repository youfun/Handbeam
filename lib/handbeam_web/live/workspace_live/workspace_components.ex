defmodule HandbeamWeb.WorkspaceLive.WorkspaceComponents do
  @moduledoc false

  use HandbeamWeb, :html

  alias HandbeamWeb.FileChangeCard

  import HandbeamWeb.WorkspaceLive.ViewComponents

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

  attr :active_file, :any, required: true
  attr :chat_scope, :any, required: true
  attr :current_workspace_id, :any, required: true
  attr :expanded_file_changes, :any, required: true
  attr :expanded_workspace_dirs, :any, required: true
  attr :file_preview_error, :any, required: true
  attr :mobile_right_panel_open, :any, required: true
  attr :revert_confirm_change_id, :any, required: true
  attr :revert_message, :any, required: true
  attr :right_panel_collapsed, :any, required: true
  attr :right_panel_view, :any, required: true
  attr :terminal_available?, :any, required: true
  attr :timeline, :any, required: true
  attr :workspace_label, :any, required: true
  attr :workspace_root, :any, required: true
  attr :workspace_tree, :any, required: true
  attr :workspace_tree_error, :any, required: true

  def workspace_panel(assigns) do
    ~H"""
    <div
      :if={@chat_scope != :free}
      id="workspace-panel"
      phx-hook="WorkspacePanel"
      class={[
        "flex-shrink-0 border-l bg-surface flex flex-col workspace-panel files-panel",
        if(@mobile_right_panel_open, do: "mobile-panel-open", else: ""),
        if(@right_panel_collapsed,
          do: "w-0 overflow-hidden border-l-0 opacity-0",
          else: "w-[440px]"
        )
      ]}
    >
      <!-- Workspace panel navigation -->
      <div class="workspace-panel-header border-b flex items-center min-w-0">
        <button
          type="button"
          phx-click="select_right_panel_view"
          phx-value-view="changes"
          class={[
            "workspace-panel-tab",
            if(@right_panel_view == :changes, do: "active", else: "")
          ]}
        >
          {gettext("Changes")}
        </button>
        <button
          type="button"
          phx-click="select_right_panel_view"
          phx-value-view="files"
          class={["workspace-panel-tab", if(@right_panel_view == :files, do: "active", else: "")]}
        >
          {gettext("Files")}
        </button>
        <button
          :if={@terminal_available?}
          type="button"
          phx-click="select_right_panel_view"
          phx-value-view="terminal"
          class={[
            "workspace-panel-tab",
            if(@right_panel_view == :terminal, do: "active", else: "")
          ]}
        >
          {gettext("Terminal")}
        </button>
        <span class="workspace-panel-label truncate">{@workspace_label}</span>
        <button
          :if={!@right_panel_collapsed}
          id="workspace-panel-toggle"
          phx-click="toggle_right_panel"
          class="workspace-panel-toggle expanded"
          title={gettext("Collapse workspace")}
          aria-label={gettext("Collapse workspace")}
          aria-pressed="true"
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <rect x="2.5" y="3" width="11" height="10" rx="1.4" />
            <path d="M10.2 3v10" />
            <path d="M7.1 6.2 5.3 8l1.8 1.8" />
          </svg>
        </button>
        <button
          id="mobile-close-workspace-panel"
          phx-click="close_mobile_right_panel"
          class="mobile-panel-close"
          title={gettext("Close")}
          aria-label={gettext("Close")}
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
          >
            <path d="M4 4l8 8M12 4l-8 8" />
          </svg>
        </button>
      </div>

      <div
        :if={@right_panel_view == :changes}
        id="workspace-changes"
        class="workspace-changes-view flex-1 min-h-0 overflow-auto"
      >
        <% changes = FileChangeCard.changes(@timeline) %>
        <p :if={changes == []} class="workspace-changes-empty">
          {gettext("No file changes yet")}
        </p>
        <.card
          :for={entry <- changes}
          entry={entry}
          open?={MapSet.member?(@expanded_file_changes, entry["id"])}
          id={"changes-file-#{entry["id"]}"}
          confirm_change_id={@revert_confirm_change_id}
          message={@revert_message}
          workspace_root={@workspace_root}
        />
      </div>

      <div
        :if={@right_panel_view == :files}
        class="workspace-files-view flex-1 min-h-0 flex flex-col"
      >
        <div class={["workspace-tree-pane", if(@active_file, do: "has-preview", else: "")]}>
          <div :if={@workspace_tree_error} class="workspace-tree-error">
            {gettext("Unable to list workspace files")}
          </div>
          <.workspace_tree
            :if={!@workspace_tree_error}
            entries={@workspace_tree}
            expanded={@expanded_workspace_dirs}
            active_file={@active_file}
            workspace_root={@workspace_root}
          />
        </div>

        <div
          :if={@active_file}
          id="editor-content"
          class="workspace-file-preview flex-1 min-h-0 overflow-auto p-4 font-mono text-sm border-t"
        >
          <div id="file-preview">
            <div>
              <div class="text-xs text-tertiary mb-2 truncate">{@active_file}</div>
              <div
                :if={@file_preview_error}
                class="p-4 bg-error-subtle border-l-4 border-l-error rounded text-sm text-error"
              >
                <span class="font-semibold">Error: </span>{@file_preview_error}
              </div>
              <pre :if={!@file_preview_error} class="text-primary"><code>{render_file_preview(@active_file, @workspace_root)}</code></pre>
            </div>
          </div>
        </div>
      </div>

      <div :if={@terminal_available? and @right_panel_view == :terminal} class="flex-1 min-h-0">
        <.live_component
          module={HandbeamWeb.Live.TerminalPanel}
          id="terminal-panel"
          workspace_id={@current_workspace_id}
          workspace_path={@workspace_root}
        />
      </div>
    </div>
    """
  end

end
