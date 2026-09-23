defmodule HandbeamWeb.FeatureCase do
  @moduledoc """
  This module defines the test case to be used by
  PhoenixTest feature tests.

  Uses PhoenixTest for unified feature testing regardless of
  whether pages are LiveView or static.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use HandbeamWeb, :verified_routes

      import HandbeamWeb.FeatureCase
      import PhoenixTest

      @endpoint HandbeamWeb.Endpoint
    end
  end

  setup tags do
    Handbeam.DataCase.setup_sandbox(tags)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> HandbeamWeb.ConnCase.authenticate()

    {:ok, conn: conn}
  end
end
