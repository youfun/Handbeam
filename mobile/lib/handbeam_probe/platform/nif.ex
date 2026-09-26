defmodule HandbeamProbe.Platform.Nif do
  @moduledoc """
  Host uses the Erlang stub. Device reuses the browser NIF pending map.
  Wire keys are a fixed atom schema — never String.to_atom/1.
  """

  alias HandbeamProbe.Platform.Request

  @wire_keys [:op, :request_id, :generation, :caller, :payload]

  def wire_keys, do: @wire_keys

  @spec command(Request.t() | map(), keyword()) :: {:ok, :async} | {:error, term()}
  def command(cmd, opts \\ [])

  def command(%Request{} = req, opts) do
    dispatch(wire_map(req), opts)
  end

  def command(cmd, _opts) when is_map(cmd) do
    {:error, :invalid_platform_request}
  end

  @doc """
  Exact map the C NIF reads: atom keys op, request_id, generation, caller, payload.
  """
  def wire_map(%Request{} = req) do
    %{
      op: req.op,
      request_id: req.request_id,
      generation: req.generation,
      caller: req.caller,
      payload: Handbeam.JSON.encode!(Map.put(req.payload, "op", req.op))
    }
  end

  @doc "Inbound `engine_result` decoding lives in `HandbeamProbe.Bridge.Inbound.engine_result/1`."
  defdelegate decode_engine_result(map), to: HandbeamProbe.Bridge.Inbound, as: :engine_result

  defp dispatch(mapped, opts) do
    if HandbeamProbe.NativePlatform.ios?() do
      HandbeamProbe.Platform.IOS.command(mapped)
    else
      android_dispatch(mapped, opts)
    end
  end

  defp android_dispatch(mapped, opts) do
    case Code.ensure_loaded(:handbeam_browser) do
      {:module, :handbeam_browser} ->
        case :handbeam_browser.command(mapped) do
          {:error, :async} -> {:ok, :async}
          {:error, :nif_not_loaded} -> host_fallback(mapped, opts)
          other -> other
        end

      {:error, _} ->
        host_fallback(mapped, opts)
    end
  end

  defp host_fallback(_cmd, _opts), do: {:error, :nif_not_loaded}
end
