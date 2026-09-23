defmodule Handbeam.ProjectTrustTest do
  use ExUnit.Case, async: false

  alias Handbeam.ProjectTrust

  setup do
    previous = Application.get_env(:handbeam, :trust_project_code)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:handbeam, :trust_project_code)
      else
        Application.put_env(:handbeam, :trust_project_code, previous)
      end
    end)

    :ok
  end

  test "project code is untrusted by default" do
    Application.delete_env(:handbeam, :trust_project_code)
    refute ProjectTrust.enabled?()
  end

  test "application config or an explicit option can trust project code" do
    Application.put_env(:handbeam, :trust_project_code, true)
    assert ProjectTrust.enabled?()
    refute ProjectTrust.enabled?(trusted_project?: false)
    assert ProjectTrust.enabled?(trusted_project?: true)
  end
end
