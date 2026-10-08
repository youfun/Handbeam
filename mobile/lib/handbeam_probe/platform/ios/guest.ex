defmodule HandbeamProbe.Platform.IOS.Guest do
  @moduledoc """
  In-process iSH guest boundary for the iOS host.

  The guest is a static library inside the one Mach-O. It is not a second
  process and it does not replace the host BEAM. Commands run only after the
  native boot path is linked; until then this module reports that the guest
  is absent.
  """

  @type result :: %{
          required(:exit_code) => integer(),
          required(:output) => String.t(),
          optional(:error_output) => String.t()
        }

  @doc """
  Run one command in the already-booted guest.

  `root` is the extracted Alpine fakefs. A missing native implementation is
  `:guest_not_linked`, not a host shell.
  """
  @spec exec(String.t(), String.t(), timeout :: pos_integer()) ::
          {:ok, result()} | {:error, :guest_not_linked | :guest_not_booted | :invalid_command}
  def exec(command, root, timeout_ms)
      when is_binary(command) and command != "" and is_binary(root) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    if linked?(), do: {:error, :guest_not_booted}, else: {:error, :guest_not_linked}
  end

  def exec(_, _, _), do: {:error, :invalid_command}

  @doc "True only when this binary was linked with the iSH static archives."
  @spec linked?() :: boolean()
  def linked?, do: Application.get_env(:handbeam_probe, :ios_guest_linked, false) == true
end
