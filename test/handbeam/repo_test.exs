defmodule Handbeam.RepoTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:handbeam, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    :ok
  end

  test "keeps an explicit database when the host also sets data_dir" do
    Handbeam.Host.put!(%{data_dir: "/tmp/handbeam-dev-data"})

    assert {:ok, config} =
             Handbeam.Repo.init(:runtime, database: "/tmp/handbeam_dev.db", pool_size: 1)

    assert config[:database] == "/tmp/handbeam_dev.db"
  end

  test "places handbeam.db beside data_dir when the host omits the database" do
    Handbeam.Host.put!(%{data_dir: "/tmp/handbeam-packaged"})

    assert {:ok, config} = Handbeam.Repo.init(:runtime, pool_size: 1)
    assert config[:database] == "/tmp/handbeam-packaged/handbeam.db"
  end

  test "leaves the configured database alone when no host data_dir is set" do
    Application.delete_env(:handbeam, :host)

    assert {:ok, config} =
             Handbeam.Repo.init(:runtime, database: "handbeam_test.db", pool_size: 1)

    assert config[:database] == "handbeam_test.db"
  end
end
