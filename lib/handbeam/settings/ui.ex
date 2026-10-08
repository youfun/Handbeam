defmodule Handbeam.Settings.UI do
  @moduledoc "Global UI preferences persisted in the application's SQLite database."
  use Ecto.Schema

  import Ecto.Changeset

  alias Handbeam.Repo

  @primary_key {:key, :string, autogenerate: false}
  schema "ui_settings" do
    field :value, :string
  end

  @doc "Return a supported locale, or nil when no valid preference has been saved."
  def locale do
    case Repo.get(__MODULE__, "ui.locale") do
      %__MODULE__{value: locale} -> valid_locale(locale)
      nil -> nil
    end
  end

  @doc "Save the language preference atomically, replacing the previous value."
  def save_locale(locale) do
    %__MODULE__{key: "ui.locale"}
    |> change(value: locale)
    |> validate_required([:value])
    |> validate_inclusion(:value, ["zh_CN", "en"])
    |> Repo.insert(on_conflict: {:replace, [:value]}, conflict_target: [:key])
    |> case do
      {:ok, _setting} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def valid_locale(locale) when locale in ["zh_CN", "en"], do: locale
  def valid_locale(_), do: nil
end
