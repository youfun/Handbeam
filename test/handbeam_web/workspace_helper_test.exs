defmodule HandbeamWeb.WorkspaceHelperTest do
  @moduledoc """
  Tests for HandbeamWeb.WorkspaceHelper — pure template helper functions
  extracted from HandbeamWeb.WorkspaceLive.
  """

  use ExUnit.Case, async: true

  alias HandbeamWeb.WorkspaceHelper

  # ── Setup for file-based tests ──

  setup do
    ws_root = Handbeam.Workspace.ensure_root!()
    {:ok, ws_root: ws_root}
  end

  # ── status_dot_class/1 ──

  describe "status_dot_class/1" do
    test "returns correct class for idle" do
      assert WorkspaceHelper.status_dot_class(:idle) == "idle"
    end

    test "returns correct class for running" do
      assert WorkspaceHelper.status_dot_class(:running) == "running"
    end

    test "returns correct class for error" do
      assert WorkspaceHelper.status_dot_class(:error) == "error"
    end

    test "returns error class for max_turns" do
      assert WorkspaceHelper.status_dot_class(:max_turns) == "error"
    end

    test "returns correct class for completed" do
      assert WorkspaceHelper.status_dot_class(:completed) == "completed"
    end

    test "returns idle for unknown status" do
      assert WorkspaceHelper.status_dot_class(:unknown) == "idle"
    end

    test "returns idle for non-atom input" do
      assert WorkspaceHelper.status_dot_class("anything") == "idle"
    end
  end

  # ── tool_status_icon/1 ──

  describe "tool_status_icon/1" do
    test "returns correct icon for running (atom)" do
      assert WorkspaceHelper.tool_status_icon(:running) == "◌"
    end

    test "returns correct icon for done (atom)" do
      assert WorkspaceHelper.tool_status_icon(:done) == "✓"
    end

    test "returns correct icon for error (atom)" do
      assert WorkspaceHelper.tool_status_icon(:error) == "✗"
    end

    test "returns correct icon for running (string)" do
      assert WorkspaceHelper.tool_status_icon("running") == "◌"
    end

    test "returns correct icon for done (string)" do
      assert WorkspaceHelper.tool_status_icon("done") == "✓"
    end

    test "returns correct icon for error (string)" do
      assert WorkspaceHelper.tool_status_icon("error") == "✗"
    end

    test "returns dot for unknown status" do
      assert WorkspaceHelper.tool_status_icon(:unknown) == "·"
    end

    test "returns dot for nil" do
      assert WorkspaceHelper.tool_status_icon(nil) == "·"
    end
  end

  # ── tool_status_class/1 ──

  describe "tool_status_class/1" do
    test "returns warning class for running (atom)" do
      assert WorkspaceHelper.tool_status_class(:running) == "text-warning"
    end

    test "returns success class for done (atom)" do
      assert WorkspaceHelper.tool_status_class(:done) == "text-success"
    end

    test "returns error class for error (atom)" do
      assert WorkspaceHelper.tool_status_class(:error) == "text-error"
    end

    test "returns warning class for running (string)" do
      assert WorkspaceHelper.tool_status_class("running") == "text-warning"
    end

    test "returns success class for done (string)" do
      assert WorkspaceHelper.tool_status_class("done") == "text-success"
    end

    test "returns error class for error (string)" do
      assert WorkspaceHelper.tool_status_class("error") == "text-error"
    end

    test "returns tertiary class for unknown" do
      assert WorkspaceHelper.tool_status_class(:unknown) == "text-tertiary"
    end
  end

  # ── tool_border_class/1 ──

  describe "tool_border_class/1" do
    test "returns warning border for running" do
      assert WorkspaceHelper.tool_border_class(:running) == "border-l-warning"
    end

    test "returns success border for done" do
      assert WorkspaceHelper.tool_border_class(:done) == "border-l-success"
    end

    test "returns error border for error" do
      assert WorkspaceHelper.tool_border_class(:error) == "border-l-error"
    end

    test "returns default border for unknown" do
      assert WorkspaceHelper.tool_border_class(:unknown) == "border border-gray-600"
    end
  end

  # ── render_tool_status/1 ──

  describe "render_tool_status/1" do
    test "returns 'running' for running atom" do
      assert WorkspaceHelper.render_tool_status(:running) == "running"
    end

    test "returns 'done' for done atom" do
      assert WorkspaceHelper.render_tool_status(:done) == "done"
    end

    test "returns 'error' for error atom" do
      assert WorkspaceHelper.render_tool_status(:error) == "error"
    end

    test "returns 'running' for running string" do
      assert WorkspaceHelper.render_tool_status("running") == "running"
    end

    test "returns 'done' for done string" do
      assert WorkspaceHelper.render_tool_status("done") == "done"
    end

    test "returns 'error' for error string" do
      assert WorkspaceHelper.render_tool_status("error") == "error"
    end

    test "returns empty string for unknown" do
      assert WorkspaceHelper.render_tool_status(:unknown) == ""
    end
  end

  # ── tool_entry_count/1 ──

  describe "tool_entry_count/1" do
    test "counts tool entries in a list" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "assistant_msg", "content" => "hello"},
        %{"content_type" => "tool", "tool" => "edit"},
        %{"content_type" => "user_msg", "content" => "hi"},
        %{:content_type => "tool", :tool => "write"}
      ]

      assert WorkspaceHelper.tool_entry_count(entries) == 3
    end

    test "returns 0 for empty list" do
      assert WorkspaceHelper.tool_entry_count([]) == 0
    end

    test "returns 0 for non-list input" do
      assert WorkspaceHelper.tool_entry_count(nil) == 0
      assert WorkspaceHelper.tool_entry_count(%{}) == 0
    end
  end

  # ── timeline_summary/1 ──

  describe "timeline_summary/1" do
    test "returns first non-empty content truncated to 80 chars" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content" => "short"},
        %{"content" => "this should not appear"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "short"
    end

    test "returns truncated content for long messages" do
      long = String.duplicate("a", 100)
      entries = [%{"content" => long}]

      assert WorkspaceHelper.timeline_summary(entries) == String.slice(long, 0, 80)
    end

    test "returns empty string when no content found" do
      entries = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "tool", "tool" => "edit"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == ""
    end

    test "returns empty string for empty list" do
      assert WorkspaceHelper.timeline_summary([]) == ""
    end

    test "returns empty string for non-list input" do
      assert WorkspaceHelper.timeline_summary(nil) == ""
    end

    test "finds content from atom-keyed entries" do
      entries = [
        %{content: "from atom key"},
        %{"content" => "from string key"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "from atom key"
    end

    test "skips entries with empty content" do
      entries = [
        %{"content" => ""},
        %{"content" => "actual content"}
      ]

      assert WorkspaceHelper.timeline_summary(entries) == "actual content"
    end
  end

  describe "user_message_nav_items/1" do
    test "keeps only user messages with 1-based indexes and truncated summaries" do
      long = String.duplicate("问", 50)

      items =
        WorkspaceHelper.user_message_nav_items([
          %{"id" => "u1", "content_type" => "user_msg", "content" => "第一轮"},
          %{"id" => "a1", "content_type" => "assistant_msg", "content" => "助手回复"},
          %{"id" => "t1", "content_type" => "tool", "content" => "read README"},
          %{"id" => "u2", "content_type" => "user_msg", "content" => long},
          %{id: "u3", content_type: "user_msg", content: "atom keyed"}
        ])

      assert Enum.map(items, & &1.id) == ["u1", "u2", "u3"]
      assert Enum.map(items, & &1.index) == [1, 2, 3]
      assert hd(items).summary == "第一轮"
      assert Enum.at(items, 1).summary == String.duplicate("问", 36) <> "…"
      assert List.last(items).summary == "atom keyed"
    end

    test "uses image or empty fallbacks and skips entries without ids" do
      items =
        WorkspaceHelper.user_message_nav_items([
          %{"content_type" => "user_msg", "content" => "no id"},
          %{
            "id" => "img",
            "content_type" => "user_msg",
            "content" => "  ",
            "attachments" => [%{}]
          },
          %{"id" => "empty", "content_type" => "user_msg", "content" => ""}
        ])

      assert Enum.map(items, &{&1.id, &1.summary}) == [
               {"img", "(image)"},
               {"empty", "(empty message)"}
             ]
    end

    test "returns empty list for non-lists" do
      assert WorkspaceHelper.user_message_nav_items(nil) == []
    end
  end

  # ── tool work collapse ──

  describe "tool_work_kind/1" do
    test "classifies file, search, and command tools" do
      assert WorkspaceHelper.tool_work_kind("read") == :file
      assert WorkspaceHelper.tool_work_kind("write") == :file
      assert WorkspaceHelper.tool_work_kind("grep") == :search
      assert WorkspaceHelper.tool_work_kind("file_search") == :search
      assert WorkspaceHelper.tool_work_kind("bash") == :command
    end
  end

  describe "browser_install_prompt/1" do
    test "returns the install card for missing-binary browser results" do
      prompt =
        WorkspaceHelper.browser_install_prompt(%{
          "tool" => "browser",
          "details" => %{"failure_category" => "missing-binary"}
        })

      assert prompt.command == "npm install -g agent-browser && agent-browser install"
      assert prompt.title =~ "agent-browser"
    end

    test "returns nil for ordinary tool errors" do
      assert WorkspaceHelper.browser_install_prompt(%{
               "tool" => "bash",
               "error" => "Permission denied"
             }) == nil
    end
  end

  describe "tool_work_summary/1" do
    test "builds Amp-style explored summaries" do
      tools = [
        %{"content_type" => "tool", "tool" => "read"},
        %{"content_type" => "tool", "tool" => "grep"},
        %{"content_type" => "tool", "tool" => "file_search"}
      ]

      assert WorkspaceHelper.tool_work_summary(tools) == "Explored 1 file, 2 searches"
    end

    test "summarizes commands" do
      tools = [%{"content_type" => "tool", "tool" => "bash"}]
      assert WorkspaceHelper.tool_work_summary(tools) == "Ran 1 command"
    end

    test "returns empty string for no tools" do
      assert WorkspaceHelper.tool_work_summary([]) == ""
    end
  end

  describe "apply_tool_work_collapse/2" do
    test "collapses a completed consecutive tool streak" do
      entries = [
        %{"id" => "u1", "content_type" => "user_msg", "content" => "go"},
        %{
          "id" => "t1",
          "content_type" => "tool",
          "tool" => "read",
          "tool_status" => "done"
        },
        %{
          "id" => "t2",
          "content_type" => "tool",
          "tool" => "grep",
          "status" => :done
        },
        %{"id" => "a1", "content_type" => "assistant_msg", "content" => "ok"}
      ]

      [user, first, second, assistant] = WorkspaceHelper.apply_tool_work_collapse(entries)

      refute Map.get(user, "work_group_id")
      assert first["work_group_id"] == "t1"
      assert first["work_group_first"]
      assert first["work_group_complete"]
      assert first["work_collapsed"]
      assert first["work_summary"] == "Explored 1 file, 1 search"
      assert second["work_group_id"] == "t1"
      refute second["work_group_first"]
      assert second["work_collapsed"]
      refute Map.get(assistant, "work_group_id")
    end

    test "keeps a running streak expanded" do
      entries = [
        %{"id" => "t1", "content_type" => "tool", "tool" => "read", "tool_status" => "done"},
        %{"id" => "t2", "content_type" => "tool", "tool" => "bash", "tool_status" => "running"}
      ]

      [first, second] = WorkspaceHelper.apply_tool_work_collapse(entries)
      refute first["work_collapsed"]
      refute second["work_collapsed"]
      refute first["work_group_complete"]
    end

    test "expands a completed group when its id is in the set" do
      entries = [
        %{"id" => "t1", "content_type" => "tool", "tool" => "read", "tool_status" => "done"}
      ]

      [first] = WorkspaceHelper.apply_tool_work_collapse(entries, MapSet.new(["t1"]))
      assert first["work_group_complete"]
      refute first["work_collapsed"]
    end
  end

  # ── format_duration/1 ──

  describe "format_duration/1" do
    test "returns nil for nil" do
      assert WorkspaceHelper.format_duration(nil) == nil
    end

    test "returns milliseconds for durations under 1s" do
      assert WorkspaceHelper.format_duration(500) == "500ms"
      assert WorkspaceHelper.format_duration(0) == "0ms"
      assert WorkspaceHelper.format_duration(999) == "999ms"
    end

    test "returns seconds for durations at or above 1s" do
      assert WorkspaceHelper.format_duration(1000) == "1.0s"
      assert WorkspaceHelper.format_duration(1500) == "1.5s"
      assert WorkspaceHelper.format_duration(12_345) == "12.3s"
    end
  end

  test "format_tokens uses decimal units, trims zeros and promotes rounded boundaries" do
    for {tokens, expected} <- [
          {0, "0"},
          {827, "827"},
          {999, "999"},
          {1000, "1K"},
          {1049, "1K"},
          {1050, "1.1K"},
          {5481, "5.5K"},
          {33_261, "33.3K"},
          {999_949, "999.9K"},
          {999_950, "1M"},
          {999_999, "1M"},
          {1_000_000, "1M"},
          {1_049_999, "1M"},
          {1_050_000, "1.1M"},
          {1_200_000, "1.2M"},
          {10_000_000, "10M"}
        ] do
      assert WorkspaceHelper.format_tokens(tokens) == expected
    end
  end

  test "cache rate uses normalized prompt totals and distinguishes cold writes from no activity" do
    assert WorkspaceHelper.format_cache_hit_rate(%{}) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 0,
             cache_read_tokens: 0,
             cache_write_tokens: 0
           }) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 0,
             cache_write_tokens: 0
           }) == "—"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 0,
             cache_write_tokens: 80
           }) == "0.0%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 100,
             cache_read_tokens: 100,
             cache_write_tokens: 0
           }) == "100.0%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 300,
             cache_read_tokens: 100,
             cache_write_tokens: 0
           }) == "33.3%"

    assert WorkspaceHelper.format_cache_hit_rate(%{
             total_input_tokens: 1000,
             cache_read_tokens: 180,
             cache_write_tokens: 750
           }) == "18.0%"
  end

  # ── format_bytes/1 ──

  describe "format_bytes/1" do
    test "returns '0 B' for nil" do
      assert WorkspaceHelper.format_bytes(nil) == "0 B"
    end

    test "returns bytes for values under 1 KB" do
      assert WorkspaceHelper.format_bytes(0) == "0 B"
      assert WorkspaceHelper.format_bytes(512) == "512 B"
      assert WorkspaceHelper.format_bytes(1023) == "1023 B"
    end

    test "returns KB for values between 1 KB and 1 MB" do
      assert WorkspaceHelper.format_bytes(1024) == "1.0 KB"
      assert WorkspaceHelper.format_bytes(1536) == "1.5 KB"
      assert WorkspaceHelper.format_bytes(1_048_575) == "1024.0 KB"
    end

    test "returns MB for values at or above 1 MB" do
      assert WorkspaceHelper.format_bytes(1_048_576) == "1.0 MB"
      assert WorkspaceHelper.format_bytes(5_242_880) == "5.0 MB"
    end
  end

  # ── diff_prefix/1 ──

  describe "diff_prefix/1" do
    test "returns '+' for insertion" do
      assert WorkspaceHelper.diff_prefix("ins") == "+"
    end

    test "returns '-' for deletion" do
      assert WorkspaceHelper.diff_prefix("del") == "-"
    end

    test "returns ' ' for eq" do
      assert WorkspaceHelper.diff_prefix("eq") == " "
    end

    test "returns '⋯' for skip" do
      assert WorkspaceHelper.diff_prefix("skip") == "⋯"
    end

    test "returns ' ' for unknown types" do
      assert WorkspaceHelper.diff_prefix("unknown") == " "
      assert WorkspaceHelper.diff_prefix(nil) == " "
    end
  end

  # ── file_value/3 ──

  describe "file_value/3" do
    test "reads atom key from map" do
      map = %{path: "/some/file.ex", name: "file.ex"}
      assert WorkspaceHelper.file_value(map, :path, nil) == "/some/file.ex"
      assert WorkspaceHelper.file_value(map, :name, nil) == "file.ex"
    end

    test "reads string key from map" do
      map = %{"path" => "/some/file.ex", "name" => "file.ex"}
      assert WorkspaceHelper.file_value(map, "path", nil) == "/some/file.ex"
    end

    test "falls back to string key when atom key missing" do
      map = %{"path" => "/other/file.ex"}
      assert WorkspaceHelper.file_value(map, :path, nil) == "/other/file.ex"
    end

    test "returns default when key not found" do
      map = %{}
      assert WorkspaceHelper.file_value(map, :path, "/default") == "/default"
    end
  end

  # ── archived_stream_count/1 ──

  describe "archived_stream_count/1" do
    test "counts archived conversations in stream entries" do
      entries = [
        {1, %{archived: true}},
        {2, %{archived: false}},
        {3, %{archived: true}},
        {4, %{archived: false}}
      ]

      assert WorkspaceHelper.archived_stream_count(entries) == 2
    end

    test "returns 0 for empty list" do
      assert WorkspaceHelper.archived_stream_count([]) == 0
    end

    test "returns 0 for non-list input" do
      assert WorkspaceHelper.archived_stream_count(nil) == 0
    end

    test "returns 0 when no archived entries" do
      entries = [
        {1, %{archived: false}},
        {2, %{archived: false}}
      ]

      assert WorkspaceHelper.archived_stream_count(entries) == 0
    end
  end

  # ── render_file_preview/2 ──

  describe "render_file_preview/2" do
    test "returns empty string for nil path", %{ws_root: ws_root} do
      assert WorkspaceHelper.render_file_preview(nil) == ""
      assert WorkspaceHelper.render_file_preview(nil, ws_root) == ""
    end

    test "returns escaped content for workspace file", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_preview.txt")
      File.write!(tmp, "hello\nworld")

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert result =~ "hello"
        assert result =~ "world"
      after
        File.rm(tmp)
      end
    end

    test "escapes HTML in preview content", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_html.txt")
      File.write!(tmp, "<script>alert('xss')</script>")

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert result =~ "&lt;script&gt;"
        refute result =~ "<script>"
      after
        File.rm(tmp)
      end
    end

    test "truncates content to 10_000 chars", %{ws_root: ws_root} do
      tmp = Path.join(ws_root, "helper_test_large.txt")
      large = String.duplicate("x", 20_000)
      File.write!(tmp, large)

      try do
        result = WorkspaceHelper.render_file_preview(tmp)
        assert String.length(result) == 10_000
      after
        File.rm(tmp)
      end
    end

    test "returns access denied for file outside workspace", %{ws_root: ws_root} do
      result = WorkspaceHelper.render_file_preview("/etc/passwd", ws_root)
      assert result =~ "Access denied"
    end

    test "returns access denied when using default workspace for non-workspace file" do
      result = WorkspaceHelper.render_file_preview("/etc/passwd")
      assert result =~ "Access denied"
    end

    test "allows file in custom workspace_root", %{ws_root: _ws_root} do
      custom_dir =
        Path.join(System.tmp_dir!(), "sigil_helper_custom_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)

      file_path = Path.join(custom_dir, "custom.exs")
      File.write!(file_path, "defmodule Custom do\n  def run, do: :custom\nend")

      try do
        # With global workspace root — access denied
        result1 = WorkspaceHelper.render_file_preview(file_path)
        assert result1 =~ "Access denied"

        # With custom workspace root — works
        result2 = WorkspaceHelper.render_file_preview(file_path, custom_dir)
        assert result2 =~ "defmodule Custom do"
        assert result2 =~ ":custom"
      after
        File.rm_rf!(custom_dir)
      end
    end

    test "returns error message for non-existent file", %{ws_root: ws_root} do
      result =
        WorkspaceHelper.render_file_preview("/nonexistent/path.txt", ws_root)

      assert result =~ "Access denied"
    end
  end

  # ── Edge cases / regression ──

  describe "edge cases" do
    test "tool_entry_count handles map keys that are atoms" do
      entries = [
        %{content_type: "tool", tool: "read"},
        %{:content_type => "tool", :tool => "write"}
      ]

      assert WorkspaceHelper.tool_entry_count(entries) == 2
    end

    test "format_bytes handles edge values precisely" do
      assert WorkspaceHelper.format_bytes(1) == "1 B"
      assert WorkspaceHelper.format_bytes(1024) == "1.0 KB"
      assert WorkspaceHelper.format_bytes(1_048_576) == "1.0 MB"
    end

    test "all helpers are deterministic" do
      # Run each helper twice, assert same result
      for _ <- 1..2 do
        assert WorkspaceHelper.status_dot_class(:idle) == "idle"
        assert WorkspaceHelper.tool_status_icon(:done) == "✓"
        assert WorkspaceHelper.tool_status_class(:error) == "text-error"
        assert WorkspaceHelper.format_duration(1500) == "1.5s"
        assert WorkspaceHelper.format_bytes(2048) == "2.0 KB"
        assert WorkspaceHelper.diff_prefix("ins") == "+"
        assert WorkspaceHelper.tool_entry_count([]) == 0
        assert WorkspaceHelper.timeline_summary([]) == ""
        assert WorkspaceHelper.render_tool_status(:running) == "running"
      end
    end
  end
end
