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

  @doc """
  Returns the first truthy value for the two keys, in the given order.

  A missing key, `nil`, and `false` fall through. `""` and `0` do not.
  The second default applies only when the second key is missing.
  """
  @spec get_first_truthy(map(), atom() | String.t(), atom() | String.t()) :: term()
  def get_first_truthy(map, first_key, second_key) when is_map(map) do
    Map.get(map, first_key) || Map.get(map, second_key)
  end

  @spec get_first_truthy(map(), atom() | String.t(), atom() | String.t(), term()) :: term()
  def get_first_truthy(map, first_key, second_key, second_missing_default) when is_map(map) do
    Map.get(map, first_key) || Map.get(map, second_key, second_missing_default)
  end

  defp safe_existing_atom_get(map, key) do
    try do
      Map.get(map, String.to_existing_atom(key))
    rescue
      ArgumentError -> nil
    end
  end
end
