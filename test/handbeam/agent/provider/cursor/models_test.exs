defmodule Handbeam.Agent.Provider.Cursor.ModelsTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Auth.Storage
  alias Handbeam.Agent.Provider.Cursor.{Models, Proto}

  defmodule FakeTransport do
    def connect(_opts), do: {:ok, %{}}

    def get_usable_models(transport, token, _opts) do
      send(Process.get(:models_test_pid), {:models_token, token})

      model =
        Proto.finish(
          Proto.encode_string(1, "composer-2.5") ++ Proto.encode_string(4, "Composer 2.5")
        )

      {:ok, transport, Proto.finish(Proto.encode_message(1, model))}
    end

    def close(t), do: t
  end

  defmodule EmptyTransport do
    def connect(_opts), do: {:ok, %{}}
    def get_usable_models(transport, _token, _opts), do: {:ok, transport, <<>>}
    def close(t), do: t
  end

  defmodule PricedTransport do
    alias Handbeam.Agent.Provider.Cursor.Proto

    def connect(_opts), do: {:ok, %{}}

    def get_usable_models(transport, _token, _opts) do
      model =
        Proto.finish(
          Proto.encode_string(1, "gpt-5.3-codex-low-fast") ++
            Proto.encode_string(4, "Codex 5.3 Low Fast")
        )

      {:ok, transport, Proto.finish(Proto.encode_message(1, model))}
    end

    def close(t), do: t
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "cursor_models_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    auth_path = Path.join(tmp, "auth.json")
    Process.put(:models_test_pid, self())

    :ok =
      Storage.put(
        "cursor",
        %{
          "type" => "oauth",
          "access" => "tok",
          "refresh" => "ref",
          "expires" => System.system_time(:millisecond) + 60_000
        },
        auth_path: auth_path
      )

    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, auth_path: auth_path}
  end

  test "discover maps account models without inventing cost 0", %{auth_path: auth_path} do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: FakeTransport)

    assert [%{"id" => "composer-2.5", "name" => "Composer 2.5"}] = models
    refute Map.has_key?(hd(models), "cost")
    assert_received {:models_token, "tok"}
    assert Models.preferred_id(models) == "composer-2.5"
  end

  test "discover attaches llm_db price for the base model id", %{auth_path: auth_path} do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: PricedTransport)

    assert [%{"id" => "gpt-5.3-codex-low-fast", "cost" => cost}] = models
    assert cost["input"] == 1.75
    assert cost["output"] == 14
  end

  test "empty catalog is an explicit error", %{auth_path: auth_path} do
    assert {:error, message} =
             Models.discover(auth_path: auth_path, transport_mod: EmptyTransport)

    assert message =~ "no usable models"
  end
end
