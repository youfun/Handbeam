defmodule Handbeam.Permissions.MatcherTest do
  use ExUnit.Case, async: true

  alias Handbeam.Permissions.Matcher

  describe "match?/2" do
    test "matches plain tool names and wildcard tool names" do
      assert Matcher.match?("read", %{name: "read", input: %{}})
      refute Matcher.match?("read", %{name: "bash", input: %{}})

      assert Matcher.match?("mem_*", %{name: "mem_recall", input: %{}})
      assert Matcher.match?("filesystem__*", %{name: "filesystem__read", input: %{}})
      refute Matcher.match?("mem_*", %{name: "read", input: %{}})
    end

    test "matches bash command patterns" do
      assert Matcher.match?("bash(rm:*)", %{
               name: "bash",
               input: %{"command" => "rm -rf tmp"}
             })

      assert Matcher.match?("bash(git push:*)", %{
               name: "bash",
               input: %{command: "git push origin master"}
             })

      refute Matcher.match?("bash(rm:*)", %{
               name: "bash",
               input: %{"command" => "git status --short"}
             })
    end

    test "matches file path patterns for edit and write" do
      assert Matcher.match?("edit(.env)", %{name: "edit", input: %{"file_path" => ".env"}})

      assert Matcher.match?("write(config/*.json)", %{
               name: "write",
               input: %{path: "config/app.json"}
             })

      refute Matcher.match?("edit(.env)", %{name: "edit", input: %{"file_path" => "README.md"}})
    end

    test "matches browser args by first command token" do
      assert Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"args" => ["eval", "document.cookie"]}
             })

      assert Matcher.match?("browser(open:*)", %{
               name: "browser",
               input: %{args: ["open", "https://example.com"]}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"args" => ["snapshot", "-i"]}
             })

      assert Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"action" => "eval", "js" => "1"}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"action" => "snapshot"}
             })
    end
  end
end
