defmodule HandbeamProbe.AndroidIntentTest do
  use ExUnit.Case, async: false

  alias HandbeamProbe.AndroidIntent

  setup do
    previous_fake = Application.get_env(:handbeam_probe, :platform_fake)
    previous_ms = Application.get_env(:handbeam_probe, :android_intent_await_ms)

    on_exit(fn ->
      if previous_fake,
        do: Application.put_env(:handbeam_probe, :platform_fake, previous_fake),
        else: Application.delete_env(:handbeam_probe, :platform_fake)

      if previous_ms,
        do: Application.put_env(:handbeam_probe, :android_intent_await_ms, previous_ms),
        else: Application.delete_env(:handbeam_probe, :android_intent_await_ms)
    end)

    :ok
  end

  test "waiter is isolated and does not drain the caller mailbox" do
    test = self()

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      send(test, {:started, req.caller, req.request_id, req.payload["deadline_ms"]})
      send(req.caller, {:engine_result, %{request_id: "other", result: "{}"}})

      send(
        req.caller,
        {:engine_result,
         %{
           request_id: req.request_id,
           result: Jason.encode!(%{outcome: "ui_presented"})
         }}
      )

      {:ok, :async}
    end)

    send(self(), {:keep_me, :inbox})

    assert {:ok, %{outcome: "ui_presented"}} =
             AndroidIntent.dispatch(%{op: :open_url, url: "https://example.com"}, %{})

    assert_received {:keep_me, :inbox}
    assert_received {:started, waiter, _id, deadline}
    assert waiter != self()
    assert is_integer(deadline)
    assert_received {:engine_result, %{request_id: "other"}}
  end

  test "timeout cancels the platform request and does not claim success" do
    test = self()
    Application.put_env(:handbeam_probe, :android_intent_await_ms, 30)

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      send(test, {:started, req.request_id})

      if req.op == "platform_cancel" do
        send(test, {:cancelled, req.payload["target_request_id"]})
        {:ok, %{ok: true}}
      else
        {:ok, :async}
      end
    end)

    assert {:error, :timeout} =
             AndroidIntent.dispatch(%{op: :open_url, url: "https://example.com/late"}, %{})

    assert_receive {:started, request_id}, 200
    assert_receive {:cancelled, ^request_id}, 200
  end
end
