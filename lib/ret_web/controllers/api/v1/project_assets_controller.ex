defmodule RetWeb.Api.V1.ProjectAssetsController do
  use RetWeb, :controller

  alias Ret.{Asset, Project, ProjectAsset, Repo, Storage}

  # Limit to 1 TPS
  plug RetWeb.Plugs.RateLimit when action in [:create]

  def index(conn, %{"project_id" => project_sid}) do
    account = Guardian.Plug.current_resource(conn)

    case Project.project_by_sid_for_account(project_sid, account) do
      %Project{} = project -> render(conn, "index.json", assets: project.assets)
      nil -> render_error_json(conn, :not_found)
    end
  end

  def create(conn, %{"project_id" => project_sid, "asset_id" => asset_sid}) do
    account = Guardian.Plug.current_resource(conn)

    with %Project{} = project <- Project.project_by_sid_for_account(project_sid, account),
         %Asset{} = asset <- Asset.asset_by_sid_for_account(asset_sid, account) do

      project_asset = Repo.get_by(ProjectAsset, [project_id: project.project_id, asset_id: asset.asset_id])
      
      if is_nil(project_asset) do
        case Project.add_asset_to_project(project, asset) do
          {:error, error} -> render_error_json(conn, error)
          %ProjectAsset{} = project_asset ->
            asset = Repo.preload(asset, [:asset_owned_file, :thumbnail_owned_file])
            render(conn, "show.json", asset: asset)
        end
      else
        asset = Repo.preload(asset, [:asset_owned_file, :thumbnail_owned_file])
        render(conn, "show.json", asset: asset)
      end
    else
      {:error, error} -> render_error_json(conn, error)
      nil -> render_error_json(conn, :not_found)
    end
  end

  def create(conn, %{"project_id" => project_sid, "asset" => params}) do
    account = conn |> Guardian.Plug.current_resource()

    case Project.project_by_sid_for_account(project_sid, account) do
      %Project{} = project -> create(conn, params, account, project)
      nil -> render_error_json(conn, :not_found)
    end
  end

  defp create(conn, params, account, project) do
    with {:ok, asset_owned_file} <-
           Storage.promote(params["file_id"], params["access_token"], nil, account),
         {:ok, thumbnail_owned_file} <-
           Storage.promote(
             params["thumbnail_file_id"],
             params["thumbnail_access_token"],
             nil,
             account
           ),
         {:ok, result} <-
           Asset.create_asset_and_project_asset(
             account,
             project,
             asset_owned_file,
             thumbnail_owned_file,
             params
           ) do
      asset = Repo.preload(result.asset, [:asset_owned_file, :thumbnail_owned_file])
      conn |> render("show.json", asset: asset)
    else
      {:error, _, changeset, %{}} -> render_error_json(conn, changeset)
      {:error, error} -> render_error_json(conn, error)
    end
  end

  def delete(conn, %{"project_id" => project_sid, "id" => asset_sid}) do
    account = Guardian.Plug.current_resource(conn)

    with %Project{} = project <- Project.project_by_sid_for_account(project_sid, account),
         %Asset{} = asset <- Asset.asset_by_sid_for_account(asset_sid, account),
         %ProjectAsset{} = project_asset <-
           Repo.get_by(ProjectAsset, project_id: project.project_id, asset_id: asset.asset_id),
         {:ok, _} <- Repo.delete(project_asset) do
      conn |> send_resp(200, "OK")
    else
      {:error, error} -> render_error_json(conn, error)
      nil -> render_error_json(conn, :not_found)
    end
  end
end
