defmodule Handbeam.Android.Tools do
  @moduledoc false

  @names ~w(android_open_url android_open_file android_share_file)

  def names, do: @names

  def known?(name) when is_binary(name), do: name in @names
  def known?(_), do: false

  def file_action?(name) when is_binary(name),
    do: name in ~w(android_open_file android_share_file)

  def file_action?(_), do: false
end
