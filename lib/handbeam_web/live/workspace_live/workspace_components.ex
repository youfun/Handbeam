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
          <span
            class={[
              "workspace-tree-chevron",
              if(MapSet.member?(@expanded, entry.relative_path), do: "is-open", else: "")
            ]}
            aria-hidden="true"
          >
            <svg
              viewBox="0 0 16 16"
              width="10"
              height="10"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M6 4.2 10 8 6 11.8" />
            </svg>
          </span>
          <.tree_icon type={:directory} />
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
        <div :if={entry.kind == :file} class="workspace-file-entry">
          <button
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
            <.tree_icon type={icon_type(entry)} />
            <span class="truncate">{entry.name}</span>
          </button>
          <.copy_relative_path path={entry.relative_path} />
        </div>
        <div
          :if={entry.kind == :symlink}
          class="workspace-file-row symlink"
          style={"--tree-depth: #{@depth}"}
          title={gettext("Symlinks are not opened from the workspace tree")}
        >
          <span class="workspace-tree-chevron" aria-hidden="true"></span>
          <.tree_icon type={:symlink} />
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
          id="workspace-panel-collapse"
          data-workspace-panel-toggle
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

  attr :path, :string, required: true

  def copy_relative_path(assigns) do
    ~H"""
    <button
      type="button"
      id={"workspace-file-copy-#{Base.url_encode64(@path, padding: false)}"}
      class="file-change-copy workspace-file-copy"
      phx-hook="CopyText"
      data-copy={@path}
      title={gettext("Copy relative path")}
      aria-label={gettext("Copy relative path")}
    >
      <svg class="copy-idle" width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
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
      <svg class="copy-done" width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path
          d="M2.5 6.2 4.8 8.5 9.5 3.5"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </button>
    """
  end

  attr :type, :atom, required: true

  def tree_icon(assigns) do
    ~H"""
    <span class="workspace-tree-icon" data-type={@type} aria-hidden="true">
      <%= case @type do %>
        <% :directory -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M2.3 6.1V4.6h3l1.1 1.1h7.2v6.4H2.3z" />
          </svg>
        <% :database -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
          >
            <ellipse cx="8" cy="4" rx="4.2" ry="1.5" />
            <path d="M3.8 4v7.5c0 .9 1.9 1.6 4.2 1.6s4.2-.7 4.2-1.6V4" />
            <path d="M3.8 7.6c0 .9 1.9 1.6 4.2 1.6s4.2-.7 4.2-1.6" />
          </svg>
        <% :image -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <rect x="2.5" y="3.2" width="11" height="9.6" rx="1.2" />
            <circle cx="5.6" cy="6.2" r=".9" />
            <path d="m3.3 11.2 2.8-2.5 1.9 1.7 1.5-1.3 2.9 2.3" />
          </svg>
        <% :markdown -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <rect x="2.4" y="3.2" width="11.2" height="9.6" rx="1.1" />
            <path d="M4.6 10.4V6.1l1.7 2.1L8 6.1v4.3M10 10.4V6.1l1.8 2.2" />
          </svg>
        <% :elixir -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M8 2.3c2.1 2.5 3.5 4.3 3.5 6.2A3.5 3.5 0 0 1 8 12a3.5 3.5 0 0 1-3.5-3.5c0-1.9 1.4-3.7 3.5-6.2z" />
          </svg>
        <% :shell -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <rect x="2.4" y="3.1" width="11.2" height="9.8" rx="1.2" />
            <path d="m4.5 6.3 2.1 1.7-2.1 1.7M8.2 9.8h3.2" />
          </svg>
        <% :config -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linecap="round"
          >
            <path d="M2.8 4.8h10.4M2.8 8h10.4M2.8 11.2h10.4" />
            <circle cx="6" cy="4.8" r="1.15" fill="currentColor" stroke="none" />
            <circle cx="10.2" cy="8" r="1.15" fill="currentColor" stroke="none" />
            <circle cx="7.2" cy="11.2" r="1.15" fill="currentColor" stroke="none" />
          </svg>
        <% :code -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M6.1 3.6 3.2 8l2.9 4.4M9.9 3.6 12.8 8 9.9 12.4" />
          </svg>
        <% :archive -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M2.6 3.4h10.8v2.4H2.6z" />
            <path d="M3.4 5.8v6c0 .5.4.8.9.8h7.4c.5 0 .9-.3.9-.8v-6" />
            <path d="M6.4 8.6h3.2" />
          </svg>
        <% :git -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <circle cx="4.2" cy="4" r="1.3" />
            <circle cx="11.6" cy="5" r="1.3" />
            <circle cx="6.2" cy="12" r="1.3" />
            <path d="M4.2 5.3v3.1c0 1.3.9 2.1 2 2.1M5.5 4.3h4.7" />
          </svg>
        <% :symlink -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M6.4 9.8 4.8 8.2a2.2 2.2 0 0 1 3.1-3.1l1.3 1.3" />
            <path d="M9.6 6.2 11.2 7.8a2.2 2.2 0 0 1-3.1 3.1L6.8 9.6" />
          </svg>
        <% _ -> %>
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.4"
            stroke-linejoin="round"
            stroke-linecap="round"
          >
            <path d="M4.2 2.4h4.7L12.5 6v7.1c0 .5-.4.9-.9.9H5.1c-.5 0-.9-.4-.9-.9V2.4z" />
            <path d="M8.8 2.5V6h3.6" />
          </svg>
      <% end %>
    </span>
    """
  end

  @doc false
  def icon_type(%{kind: :directory}), do: :directory
  def icon_type(%{kind: :symlink}), do: :symlink
  def icon_type(%{kind: :file, name: name}), do: file_icon_type(name)
  def icon_type(%{name: name}) when is_binary(name), do: file_icon_type(name)

  @doc false
  def file_icon_type(name) when is_binary(name) do
    base = name |> Path.basename() |> String.downcase()
    ext = base |> Path.extname() |> String.trim_leading(".")

    cond do
      base in ~w(dockerfile makefile license copying) ->
        :config

      String.starts_with?(base, ".git") ->
        :git

      ext in ~w(db sqlite sqlite3 db-shm db-wal) or String.contains?(base, ".db-") ->
        :database

      ext in ~w(png jpg jpeg gif webp svg ico icns bmp heic) ->
        :image

      ext in ~w(md markdown mdx) ->
        :markdown

      ext in ~w(ex exs heex eex erl hrl) ->
        :elixir

      ext in ~w(sh bash zsh fish) ->
        :shell

      ext in ~w(json jsonc yml yaml toml xml plist conf config ini env lock mobileprovision p12 pem crt cer) ->
        :config

      ext in ~w(js mjs cjs ts tsx jsx css scss py rb go rs swift kt java c h cpp hpp) ->
        :code

      ext in ~w(zip tar gz tgz bz2 xz 7z rar) ->
        :archive

      true ->
        :file
    end
  end
end
