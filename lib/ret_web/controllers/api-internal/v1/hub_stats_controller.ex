defmodule RetWeb.ApiInternal.V1.HubStatsController do
  use RetWeb, :controller
  alias Ret.NodeStat

  # Params start_time and end_time should be in iso format such as "2000-02-28 23:00:13"
  # or what is returned from NaiveDateTime.to_string()
  def hub_stats(conn, %{"start_time" => start_time_str, "end_time" => end_time_str}) do
    conn = put_resp_header(conn, "content-type", "application/json")

    case Ret.Storage.storage_used() do
      {:ok, storage_used_kb} when is_number(storage_used_kb) ->
        max_ccu =
          NodeStat.max_ccu_for_time_range(
            start_time_str |> NaiveDateTime.from_iso8601!(),
            end_time_str |> NaiveDateTime.from_iso8601!()
          )

        conn |> send_resp(200, %{max_ccu: max_ccu, storage_mb: storage_used_kb / 1024} |> Poison.encode!())

      _ ->
        send_resp(conn, 503, %{error: :storage_usage_unavailable} |> Poison.encode!())
    end
  end
end
