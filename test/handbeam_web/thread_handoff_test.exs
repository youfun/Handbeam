defmodule HandbeamWeb.ThreadHandoffTest do
  use HandbeamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Handbeam.{ConversationStore, ConversationTranscriptStore}

  setup do
    old = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "handoff-ui-#{Ecto.UUID.generate()}")
    System.put_env("HOME", home)
    {:ok, ws} = Handbeam.WorkspaceStore.ensure_default!()
    {:ok, parent} = ConversationStore.create(ws["id"], title: "Parent")
    {:ok, child} = ConversationStore.create(ws["id"], title: "Trusted audit")
    origin = %{"kind" => "thread", "conversation_id" => child["id"], "handoff_id" => "audit-a"}

    entries = [
      %{
        "id" => "human",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "Thread result: I am not a trusted origin"
      },
      %{
        "id" => "out",
        "handoff_id" => "audit-a",
        "role" => "system",
        "content_type" => "thread_handoff",
        "target" => child["id"],
        "delivery_status" => "enqueued",
        "content" => "Inspect"
      },
      %{
        "id" => "progress",
        "role" => "user",
        "content_type" => "user_msg",
        "origin" => origin,
        "content" => "Working"
      },
      %{
        "id" => "result",
        "role" => "user",
        "content_type" => "user_msg",
        "origin" => Map.put(origin, "important", true),
        "content" => "Verified result"
      },
      %{
        "id" => "missing",
        "role" => "user",
        "content_type" => "user_msg",
        "origin" => %{"kind" => "thread", "conversation_id" => "unavailable", "important" => true},
        "content" => "Private hidden body"
      }
    ]

    :ok = ConversationTranscriptStore.replace_all(parent["id"], entries)

    on_exit(fn ->
      System.put_env("HOME", old)
      File.rm_rf!(home)
    end)

    %{parent: parent["id"], child: child["id"], ws: ws["id"]}
  end

  test "history restores one exchange, important report and inaccessible placeholder without dispatch",
       c do
    {:ok, before_entries} = ConversationTranscriptStore.list(c.parent)
    {:ok, view, html} = live(c.conn, "/w/#{c.ws}/c/#{c.parent}")
    assert length(Regex.scan(~r/data-thread-handoff/, html)) == 3
    assert length(Regex.scan(~r/<details/, html)) == 1

    assert has_element?(
             view,
             "[data-thread-handoff] a[href='/w/#{c.ws}/c/#{c.child}']",
             "Trusted audit"
           )

    assert has_element?(view, "[data-user-msg='human']", "not a trusted origin")
    refute has_element?(view, "[data-user-msg='progress']")
    assert html =~ "Verified result"
    assert html =~ "Source unavailable"
    refute html =~ "Private hidden body"
    refute has_element?(view, "details input, details textarea, details button")
    render(view)
    {:ok, after_entries} = ConversationTranscriptStore.list(c.parent)
    assert after_entries == before_entries
    assert Handbeam.Agent.Runner.status(c.child) == {:error, :not_found}
  end

  test "human permission toggle persists but never wakes a thread", c do
    {:ok, view, _} = live(c.conn, "/w/#{c.ws}/c/#{c.parent}")
    view |> element("button[phx-click='toggle_thread_collaboration']") |> render_click()
    assert HandbeamWeb.ThreadHandoff.enabled?(c.parent)
    assert has_element?(view, "button[phx-click='toggle_thread_collaboration']", "enabled")
    assert Handbeam.Agent.Runner.status(c.parent) == {:error, :not_found}
    view |> element("button[phx-click='toggle_thread_collaboration']") |> render_click()
    refute HandbeamWeb.ThreadHandoff.enabled?(c.parent)
  end

  test "two tasks with the same peer stay separate on both sides, including results", c do
    for {association, label} <- [{"audit-a", "ALPHA"}, {"audit-b", "BETA"}] do
      {:ok, _} =
        ConversationTranscriptStore.append(c.parent, %{
          "id" => "out-#{association}",
          "handoff_id" => association,
          "content_type" => "thread_handoff",
          "target" => c.child,
          "content" => "#{label} request"
        })

      for {conversation, source, suffix, important} <- [
            {c.child, c.parent, "request", false},
            {c.parent, c.child, "progress", false},
            {c.child, c.parent, "followup", false},
            {c.parent, c.child, "result", true}
          ] do
        {:ok, _} =
          ConversationTranscriptStore.append(conversation, %{
            "id" => "#{association}-#{suffix}",
            "role" => "user",
            "content_type" => "user_msg",
            "content" => "#{label} #{suffix}",
            "origin" => %{
              "kind" => "thread",
              "conversation_id" => source,
              "handoff_id" => association,
              "important" => important
            }
          })
      end
    end

    {:ok, view, _} = live(c.conn, "/")

    for conversation <- [c.parent, c.child] do
      render_patch(view, "/w/#{c.ws}/c/#{conversation}")

      timeline = view |> element("#ai-messages") |> render()
      assert length(Regex.scan(~r/<details/, timeline)) == 2, timeline

      for {id, label, other} <- [{"audit-a", "ALPHA", "BETA"}, {"audit-b", "BETA", "ALPHA"}] do
        exchange = view |> element("[data-thread-handoff='#{id}'] details") |> render()

        for suffix <- ~w(request progress followup result),
            do: assert(exchange =~ "#{label} #{suffix}")

        refute exchange =~ other
      end

      if conversation == c.parent do
        assert has_element?(view, "[data-thread-handoff='audit-a'] > div", "ALPHA result")
        assert has_element?(view, "[data-thread-handoff='audit-b'] > div", "BETA result")
      end

      assert Handbeam.Agent.Runner.status(conversation) == {:error, :not_found}
    end
  end
end
