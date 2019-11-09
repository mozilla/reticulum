defmodule Ret.AppConfig do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ret.{AppConfig, Repo, OwnedFile}

  @schema_prefix "ret0"
  @primary_key {:app_config_id, :id, autogenerate: true}

  schema "app_configs" do
    field(:key, :string)
    field(:value, :map)
    belongs_to(:owned_file, Ret.OwnedFile, references: :owned_file_id)
    timestamps()
  end

  def interval, do: :timer.seconds(15)

  def changeset(%AppConfig{} = app_config, key, %OwnedFile{} = owned_file) do
    app_config
    |> cast(%{key: key}, [:key])
    |> put_change(:owned_file_id, owned_file.owned_file_id)
    |> unique_constraint(:key)
  end

  def changeset(%AppConfig{} = app_config, attrs) do
    # We wrap the config value in an outer %{value: ...} map because we want to be able to accept primitive
    # value types, but store them as json.
    attrs = attrs |> Map.put(:value, %{value: attrs.value})

    app_config
    |> cast(attrs, [:key, :value])
    |> unique_constraint(:key)
  end

  def get_config(skip_cache \\ false) do
    result = if skip_cache do fetch_config("") else Cachex.fetch(:app_config, "") end 

    case result do
      { status, config } when status in [:commit, :ok] -> config

  def get_config_value(key) do
    case AppConfig |> Repo.get_by(key: key) do
      %AppConfig{} = app_config -> app_config.value["value"]
      nil -> nil
    end
  end

  def fetch_config(_arg) do
    config =
      AppConfig
      |> Repo.all()
      |> Repo.preload(:owned_file)
      |> Enum.map(fn app_config -> expand_key(app_config.key, app_config) end)
      |> Enum.reduce(%{}, fn config, acc -> deep_merge(acc, config) end)

    {:commit, config}
  end

  defp expand_key(key, app_config) do
    if key |> String.contains?("|") do
      [head, tail] = key |> String.split("|", parts: 2)
      %{head => expand_key(tail, app_config)}
    else
      case app_config.owned_file do
        %OwnedFile{} ->
          %{key => app_config.owned_file |> OwnedFile.uri_for() |> URI.to_string()}

        _ ->
          %{key => app_config.value["value"]}
      end
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, &deep_resolve/3)
  end

  defp deep_resolve(_key, left = %{}, right = %{}) do
    deep_merge(left, right)
  end

  defp deep_resolve(_key, _left, right) do
    right
  end

  def collapse(config, parent_key \\ "") do
    case config do
      %{"file_id" => _} -> [{parent_key |> String.trim("|"), config}]
      %{} -> config |> Enum.flat_map(fn {key, val} -> collapse(val, parent_key <> "|" <> key) end)
      _ -> [{parent_key |> String.trim("|"), config}]
    end
  end
end
