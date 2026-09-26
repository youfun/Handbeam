defmodule Handbeam.Extension.ResolveEntryTest do
  use ExUnit.Case, async: true

  # We test the private resolve_entry/2 by going through Extension.new/2
  # which is the public entry point that calls resolve_entry internally.
  #
  # Sibling-prefix bypass: root = /home/me/.handbeam/extensions/foo
  #   entry resolves to /home/me/.handbeam/extensions/foo-evil/payload.js
  #   -> {0, _} falsely matches because "foo-evil" starts with "foo"

  describe "resolve_entry path containment" do
    test "accepts entry inside the extension root" do
      root = "/home/me/.handbeam/extensions/my-ext"
      manifest = build_manifest("my-ext", "lib/my_ext.ex")
      assert {:ok, _ext} = Handbeam.Extension.new(manifest, root)
    end

    test "rejects sibling-prefix bypass: foo-evil under foo" do
      root = "/home/me/.handbeam/extensions/foo"
      entry = "../foo-evil/payload.js"
      # Path.expand("../foo-evil/payload.js", "/home/me/.handbeam/extensions/foo")
      # => "/home/me/.handbeam/extensions/foo-evil/payload.js"
      # With {0, _} prefix check this wrongly passes.
      manifest = build_manifest("foo", entry)
      assert {:error, _diag} = Handbeam.Extension.new(manifest, root)
    end

    test "rejects path that escapes root via ../" do
      root = "/home/me/.handbeam/extensions/my-ext"
      entry = "../../etc/shadow"
      manifest = build_manifest("my-ext", entry)
      assert {:error, _diag} = Handbeam.Extension.new(manifest, root)
    end

    test "accepts nil entry" do
      manifest = build_manifest("my-ext", nil)
      assert {:ok, ext} = Handbeam.Extension.new(manifest, "/home/me/.handbeam/extensions/my-ext")
      assert ext.entry == nil
    end
  end

  defp build_manifest(name, entry) do
    %Handbeam.Extension.Manifest{
      name: name,
      version: "0.1.0",
      description: "test",
      entry: entry,
      enabled: true,
      permissions: %{},
      hooks: [],
      tools: [],
      commands: [],
      providers: [],
      metadata: %{}
    }
  end
end
