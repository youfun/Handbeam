defmodule Handbeam.Utils.SafeMap do
  @moduledoc """
  Safe map key access without dynamic atom creation.

  Replaces the unsafe pattern:
      Map.get(map, key) || Map.get(map, String.to_atom(key))
  which creates atoms from arbitrary strings (DoS risk).
  """

  @doc """
  Gets a value from a map, trying both string and existing atom keys.

  Uses `String.to_existing_atom/1` wrapped in try/rescue to avoid
  creating new atoms from untrusted input.

  ## Examples

      iex> SafeMap.get(%{"foo" => 1}, "foo")
      1

      iex> SafeMap.get(%{foo: 1}, "foo")
      1

      iex> SafeMap.get(%{}, "bar")
      nil
  """
  @spec get(map(), String.t()) :: term()
  def get(map, key) when is_binary(key) do
    Map.get(map, key) || safe_existing_atom_get(map, key)
  end

  defp safe_existing_atom_get(map, key) do
    try do
      Map.get(map, String.to_existing_atom(key))
    rescue
      ArgumentError -> nil
    end
  end
end
