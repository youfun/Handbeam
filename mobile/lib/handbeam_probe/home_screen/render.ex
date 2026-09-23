defmodule HandbeamProbe.HomeScreen.Render do
  @moduledoc """
  Pure projection of `HandbeamProbe.HomeScreen.State` into Mob nodes. No IO: sent
  image paths are precomputed on the chat entries, and every collaborator
  render function is a pure function of the assigns it receives.
  """

  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  alias HandbeamProbe.HomeScreen.{Notice, Share}

  alias HandbeamProbe.{
    ModelSettings,
    MCPSettings,
    GitSettings,
    NativeApproval,
    NativeComposer,
    NativeTimeline,
    NativeWorkspaceOpen,
    NativeWorkspaces,
    NativeWorkspaceTree
  }

  def render(a) do
    if NativeWorkspaceOpen.overlay?(a) do
      NativeWorkspaceOpen.render_overlay(a)
    else
      shell(a)
    end
  end

  defp shell(%{page: page_name} = a) when page_name in [:chat, :history] do
    node(
      :box,
      [
        fill_width: true,
        fill_height: true,
        background: color(:surface),
        history_shell: true,
        drawer_open: page_name == :history,
        back_target: if(page_name == :history, do: inspect({:page, :chat}))
      ],
      [
        render_page(%{a | page: :chat, approval_open: a.approval_open and page_name == :chat}),
        if(page_name == :history, do: render_page(a))
      ]
    )
  end

  defp shell(a), do: render_page(a)

  defp render_page(a) do
    back_target = if a.page != :chat, do: inspect({:page, :chat})
    notice = Map.get(a, :notice)

    page(
      [
        header(a),
        notice(if(a.stopping, do: gettext("Stopping…"), else: Notice.text(notice))),
        content(a),
        if(a.page != :history, do: HandbeamProbe.NativeModelInputs.render(a.input_warning)),
        if(a.page == :chat && a.chat && a.chat.pending_approval && a.approval_open,
          do:
            NativeApproval.render(
              a.chat,
              Notice.error_text(notice),
              Map.get(a, :approval_snapshots, %{})
            )
        )
      ],
      back_target: back_target
    )
  end

  defp header(%{page: :chat} = a) do
    row([
      icon("menu", {:page, :history}),
      text(gettext("Handbeam"), text_size: 13, font_weight: "bold", padding_right: 8),
      button(
        (a.workspace && a.workspace["name"]) || gettext("Workspace"),
        {:page, :workspace},
        text_size: 11,
        weight: 1,
        background: color(:surface)
      ),
      button(gettext("Files"), {:page, :files}, text_size: 11, background: color(:surface)),
      icon("info", {:page, :about}),
      icon("settings", {:page, :settings})
    ])
  end

  defp header(a) do
    row([
      icon("back", {:page, :chat}),
      text(page_title(a.page), text_size: 14, weight: 1)
    ])
  end

  defp content(%{page: :chat} = a) do
    entries = if a.chat, do: a.chat.entries, else: []
    stream = if a.chat, do: a.chat.stream, else: ""
    running = a.chat != nil and a.chat.running

    node(:column, [weight: 1, fill_width: true], [
      Share.render_review(Map.get(a, :share_intakes, []), a),
      NativeTimeline.render_sent_card(a.chat, Map.get(a, :timeline_open)),
      if(a.chat && a.chat.pending_approval,
        do:
          button(gettext("Waiting for tool approval · Review"), :review_approval,
            fill_width: true
          )
      ),
      if(entries == [] and stream == "" and not running,
        do: empty_chat(),
        else:
          scroll(NativeTimeline.render(a.chat, a.work_groups, a.work_segments, a.tool_outputs),
            id: "chat-timeline-#{a.chat.conversation["id"]}",
            chat_navigation: true,
            stick_to_bottom: true
          )
      ),
      composer_controls(a),
      NativeComposer.render_field(a, running)
    ])
  end

  defp content(%{page: :attachments} = a),
    do:
      scroll(
        NativeComposer.render_entries(a) ++ [button(gettext("Back to chat"), {:page, :chat})]
      )

  defp content(%{page: :history} = a) do
    scroll(
      [row([text(gettext("Conversations"), weight: 1), icon("add", :new_chat)])] ++
        HandbeamProbe.NativeHistory.render(
          a.history,
          a.inactive_history_open,
          a.chat && a.chat.conversation["id"]
        )
    )
  end

  defp content(%{page: :files} = a),
    do: NativeWorkspaceTree.render(a.workspace_tree || NativeWorkspaceTree.idle())

  defp content(%{page: :permissions} = a),
    do: scroll(NativeApproval.render_modes(a.permission_mode))

  defp content(%{page: :settings} = a), do: content(%{a | page: :models})

  defp content(%{page: page} = a)
       when page in [:models, :workspace, :mcp, :git, :appearance] do
    node(:column, [weight: 1, fill_width: true], [
      settings_tabs(page),
      settings_body(a),
      if(page == :models, do: ModelSettings.confirm_sheet(a.models))
    ])
  end

  defp content(_a),
    do:
      scroll([
        text(gettext("Not implemented yet"), text_size: 16, padding_top: 32),
        text(gettext("This native experiment only opens chat, workspaces, and model settings."),
          padding_top: 12
        ),
        button(gettext("Back to chat"), {:page, :chat})
      ])

  defp empty_chat do
    node(:box, [weight: 1, align: "center"], [
      node(:column, [fill_width: true], [
        text(gettext("Start a new conversation"),
          text_size: 16,
          fill_width: true,
          text_align: "center"
        ),
        text(gettext("Send a message and work with AI"),
          text_size: 13,
          text_color: color(:hint),
          padding_top: 8,
          fill_width: true,
          text_align: "center"
        )
      ])
    ])
  end

  defp settings_tabs(page) do
    node(:column, [fill_width: true, padding_bottom: 8], [
      segment_row([
        tab_button(gettext("Model / AI"), {:page, :models}, page == :models),
        tab_button(gettext("Workspaces"), {:page, :workspace}, page == :workspace)
      ]),
      segment_row(
        [
          tab_button(gettext("MCP"), {:page, :mcp}, page == :mcp),
          tab_button(gettext("Git"), {:page, :git}, page == :git),
          tab_button(gettext("UI"), {:page, :appearance}, page == :appearance,
            background: if(page == :appearance, do: color(:muted), else: color(:control)),
            text_color: if(page == :appearance, do: color(:card), else: color(:muted))
          )
        ],
        padding_top: 8
      )
    ])
  end

  defp settings_body(%{page: :models} = a),
    do: scroll(ModelSettings.render(a.models), id: "models-#{inspect(a.models.editing)}")

  defp settings_body(%{page: :workspace} = a),
    do: NativeWorkspaces.render(a.workspaces, a.workspace)

  defp settings_body(%{page: :mcp} = a),
    do: MCPSettings.render(a.mcp, a.workspaces.items)

  defp settings_body(%{page: :git} = a),
    do: GitSettings.render(a.git)

  defp settings_body(%{page: :appearance}) do
    scroll([
      card([
        text(gettext("Appearance is not available yet"), text_size: 16),
        text(
          gettext(
            "Theme and display options are not part of this native experiment. Chat, workspaces, and model settings are available."
          ),
          text_size: 13,
          text_color: color(:muted),
          padding_top: 8
        )
      ])
    ])
  end

  defp page_title(:history), do: gettext("Conversations")
  defp page_title(:attachments), do: gettext("Attachments")
  defp page_title(:files), do: gettext("Workspace files")
  defp page_title(_), do: gettext("Settings")

  defp composer_controls(a) do
    model_opts =
      Enum.map(a.models.allowed_models, fn model ->
        select_option(
          model.name,
          {:composer_setting, :default_model, model.id},
          model.id == a.models.default,
          composer_option_chrome()
        )
      end)

    reasoning_opts =
      Enum.map(Handbeam.Agent.Reasoning.levels(), fn level ->
        select_option(
          level,
          {:composer_setting, :reasoning, level},
          level == a.models.reasoning,
          composer_option_chrome()
        )
      end)

    permission_opts =
      Enum.map([:auto, :prompt, :deny], fn mode ->
        select_option(
          NativeApproval.mode_label(mode),
          {:permission_mode, mode},
          mode == a.permission_mode,
          composer_option_chrome()
        )
      end)

    chips = [
      composer_select(a, :model, model_name(a.models), model_opts, "composer-model"),
      composer_select(a, :reasoning, a.models.reasoning, reasoning_opts, "composer-reasoning"),
      composer_select(
        a,
        :permission,
        NativeApproval.mode_label(a.permission_mode),
        permission_opts,
        "composer-permission"
      )
    ]

    if HandbeamProbe.NativePlatform.ios?() do
      node(:column, [fill_width: true], [
        composer_open_menu(a, model_opts, reasoning_opts, permission_opts),
        row(spaced(chips), align: "center", padding_bottom: 6)
      ])
    else
      [model, reasoning, permission] = chips

      row(
        [model, gap(6), reasoning, node(:box, weight: 1), permission],
        padding_bottom: 4
      )
    end
  end

  # Compact menuitem chrome for the composer overlay. Settings keep the
  # NativeUI defaults. Padding 10 × six reasoning levels stacked inside a
  # chip column is what shoved the menu into the input field.
  defp composer_option_chrome do
    if HandbeamProbe.NativePlatform.ios?() do
      [padding: 6, text_size: 12]
    else
      []
    end
  end

  defp composer_open_menu(a, model_opts, reasoning_opts, permission_opts) do
    options =
      case a.composer_select do
        :model -> model_opts
        :reasoning -> reasoning_opts
        :permission -> permission_opts
        _ -> nil
      end

    if options do
      node(
        :column,
        [
          fill_width: true,
          background: color(:card),
          border_color: color(:ink),
          border_width: 1,
          corner_radius: 8,
          padding: 4
        ],
        options
      )
    end
  end

  defp composer_select(a, which, value, options, id) do
    select(value, options,
      id: id,
      compact: true,
      fill_width: false,
      text_size: 11,
      icon_content_description: gettext("Open menu"),
      # iOS chips stay collapsed; the open menu is a sibling above the row.
      open: not HandbeamProbe.NativePlatform.ios?() and a.composer_select == which,
      on_toggle: {:composer_select, which}
    )
  end

  defp model_name(models) do
    if is_binary(models.chat_blocked) do
      models.chat_blocked
    else
      case Enum.find(models.allowed_models, &(&1.id == models.default)) ||
             Enum.find(models.models, &(&1.id == models.default)) do
        nil -> gettext("Select a model")
        model -> model.name
      end
    end
  end
end
