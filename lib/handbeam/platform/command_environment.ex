defmodule Handbeam.Platform.CommandEnvironment do
  @moduledoc false

  @release_env ~w(BINDIR EMU PROGNAME RELEASE_NAME RELEASE_ROOT RELEASE_VSN ROOTDIR)

  @spec sanitize(map()) :: map()
  def sanitize(environment) when is_map(environment) do
    environment
    |> Map.drop(@release_env)
    |> Map.update("PATH", nil, &strip_release_erts/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec port_env(map()) :: [{String.t(), String.t() | false}]
  def port_env(environment) when environment == %{}, do: []

  def port_env(environment) when is_map(environment) do
    environment = sanitize(environment)
    removed = Map.keys(System.get_env()) -- Map.keys(environment)
    Enum.map(removed, &{&1, false}) ++ Map.to_list(environment)
  end

  @spec encode_port_env([{String.t(), String.t() | false}]) ::
          [{charlist(), charlist() | false}]
  def encode_port_env(environment) when is_list(environment) do
    Enum.map(environment, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  @spec find_executable(String.t(), map()) :: String.t() | nil
  def find_executable(name, environment) when is_binary(name) and is_map(environment) do
    environment
    |> Map.get("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, name)

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> path
        _ -> nil
      end
    end)
  end

  @spec strip_release_erts(String.t()) :: String.t()
  def strip_release_erts(path) when is_binary(path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reject(&release_erts_dir?/1)
    |> Enum.join(":")
  end

  defp release_erts_dir?(dir) do
    expanded = Path.expand(dir)
    erts = Path.dirname(expanded)
    release = Path.dirname(erts)

    not Handbeam.Host.packaged_mix_toolchain?() and
      Path.basename(expanded) == "bin" and
      String.starts_with?(Path.basename(erts), "erts-") and
      File.regular?(Path.join(release, "releases/start_erl.data"))
  end
end
