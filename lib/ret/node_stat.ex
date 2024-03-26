defmodule Ret.NodeStat do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Ret.{NodeStat, Repo}
  @schema_prefix "ret0"
  @primary_key false

  schema "node_stats" do
    field :node_id, :binary
    field :measured_at, :utc_datetime
    field :present_sessions, :integer
    field :present_rooms, :integer
  end

  def changeset(%NodeStat{} = node_stat, attrs) do
    node_stat
    |> cast(attrs, [
      :node_id,
      :measured_at,
      :present_sessions,
      :present_rooms
    ])
  end

  @spec max_ccu_for_time_range(DateTime.t(), DateTime.t()) :: number()
  def max_ccu_for_time_range(start_time, end_time) do
    start_time_truncated = start_time |> NaiveDateTime.truncate(:second)
    end_time_truncated = end_time |> NaiveDateTime.truncate(:second)

    max_ccu =
      Repo.one(
        from stat in NodeStat,
          select: max(stat.present_sessions),
          where: stat.measured_at >= ^start_time_truncated,
          where: stat.measured_at < ^end_time_truncated
      )

    # Can I check that the db actually has the time range? So we could technically fill in previous data.

    if max_ccu === nil, do: 0, else: max_ccu
  end
end
