defmodule RetWeb.SessionSocket do
  use Phoenix.Socket

  channel("ret", RetWeb.RetChannel)
  channel("hub:*", RetWeb.HubChannel)
  channel("link:*", RetWeb.LinkChannel)
  channel("auth:*", RetWeb.AuthChannel)
  channel("oidc:*", RetWeb.OIDCAuthChannel)

  def id(socket) do
    "session:#{socket.assigns.session_id}"
  end

  def connect(%{"session_token" => session_token}, socket) do
    socket =
      socket
      |> assign(:session_id, session_token |> session_id_for_token || generate_session_id())
      |> assign(:started_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    {:ok, socket}
  end

  def connect(%{}, socket) do
    socket =
      socket
      |> assign(:session_id, generate_session_id())
      |> assign(:started_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    {:ok, socket}
  end

  defp session_id_for_token(session_token) do
    case session_token |> Ret.SessionToken.decode_and_verify() do
      {:ok, %{"session_id" => session_id}} -> session_id
      _ -> nil
    end
  end

  defp generate_session_id(), do: SecureRandom.uuid()
end
