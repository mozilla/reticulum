defmodule RetWeb.OIDCAuthChannel do
  @moduledoc "Ret Web Channel for OpenID Connect Authentication"

  use RetWeb, :channel
  import Canada, only: [can?: 2]

  alias Ret.{Statix, Account, OAuthToken, RemoteOIDCToken}

  intercept(["auth_credentials"])

  def join("oidc:" <> _topic_key, _payload, socket) do
    # Expire channel in 5 minutes
    Process.send_after(self(), :channel_expired, 60 * 1000 * 5)

    # Rate limit joins to reduce attack surface
    :timer.sleep(500)

    Statix.increment("ret.channels.oidc.joins.ok")
    {:ok, %{session_id: socket.assigns.session_id}, socket}
  end

  defp module_config(key) do
    Application.get_env(:ret, __MODULE__)[key]
  end

  defp get_redirect_uri(), do: RetWeb.Endpoint.url() <> "/verify"

  defp get_authorize_url(state, nonce) do
    "#{module_config(:auth_endpoint)}?" <>
      URI.encode_query(%{
        response_type: "code",
        response_mode: "query",
        client_id: module_config(:client_id),
        scope: "openid profile",
        state: state,
        nonce: nonce,
        redirect_uri: get_redirect_uri()
      })
  end

  def handle_in("auth_request", _payload, socket) do
    if Map.get(socket.assigns, :nonce) do
      {:reply, {:error, "Already started an auth request on this session"}, socket}
    else
      "oidc:" <> topic_key = socket.topic
      oidc_state = Ret.OAuthToken.token_for_oidc_request(topic_key, socket.assigns.session_id)
      nonce = SecureRandom.uuid()
      authorize_url = get_authorize_url(oidc_state, nonce)

      socket = socket |> assign(:nonce, nonce)

      {:reply, {:ok, %{authorize_url: authorize_url}}, socket}
    end
  end

  def handle_in("auth_verified", %{"token" => code, "payload" => state}, socket) do
    Process.send_after(self(), :close_channel, 1000 * 5)

    # Slow down any brute force attacks
    :timer.sleep(500)

    "oidc:" <> expected_topic_key = socket.topic

    with {:ok,
          %{
            "topic_key" => topic_key,
            "session_id" => session_id,
            "aud" => "ret_oidc"
          }}
         when topic_key == expected_topic_key <- OAuthToken.decode_and_verify(state),
         {:ok,
          %{
            "access_token" => _access_token,
            "id_token" => raw_id_token
          }} <- fetch_oidc_tokens(code),
         {:ok,
          %{
            "aud" => _aud,
            "nonce" => nonce,
            "sub" => remote_user_id
          } = id_token} <- RemoteOIDCToken.decode_and_verify(raw_id_token) do
      # TODO we may want to verify some more fields like issuer and expiration time

      displayname =
        id_token
        |> Map.get(
          "preferred_username",
          id_token |> Map.get("name", remote_user_id)
        )

      broadcast_credentials_and_payload(
        remote_user_id,
        %{displayName: displayname},
        %{session_id: session_id, nonce: nonce},
        socket
      )

      {:reply, :ok, socket}
    else
      # intentionally not exposing the nature of the error, can uncomment this to return more details to the client
      # {:error, error} ->
      #   {:reply, {:error, %{message: error}}, socket}

      _ ->
        {:reply, {:error, %{message: "error fetching or verifying token"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  def fetch_oidc_tokens(oauth_code) do
    body =
      {:form,
       [
         client_id: module_config(:client_id),
         client_secret: module_config(:client_secret),
         grant_type: "authorization_code",
         redirect_uri: get_redirect_uri(),
         code: oauth_code,
         scope: "openid profile"
       ]}

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Ret.HttpUtils.retry_post_until_success("#{module_config(:token_endpoint)}", body, headers) do
      %HTTPoison.Response{body: body} -> body |> Poison.decode()
      _ -> {:error, "Failed to fetch tokens"}
    end
  end

  def handle_info(:close_channel, socket) do
    GenServer.cast(self(), :close)
    {:noreply, socket}
  end

  def handle_info(:channel_expired, socket) do
    GenServer.cast(self(), :close)
    {:noreply, socket}
  end

  # Only send creddentials back down to the original socket that started the request
  def handle_out(
        "auth_credentials" = event,
        %{credentials: credentials, user_info: user_info, verification_info: verification_info},
        socket
      ) do
    Process.send_after(self(), :close_channel, 1000 * 5)

    if Map.get(socket.assigns, :session_id) == Map.get(verification_info, :session_id) and
         Map.get(socket.assigns, :nonce) == Map.get(verification_info, :nonce) do
      push(socket, event, %{credentials: credentials, user_info: user_info})
    end

    {:noreply, socket}
  end

  defp broadcast_credentials_and_payload(nil, _user_info, _verification_info, _socket), do: nil

  defp broadcast_credentials_and_payload(identifier_hash, user_info, verification_info, socket) do
    account_creation_enabled = can?(nil, create_account(nil))
    account = identifier_hash |> Account.account_for_login_identifier_hash(account_creation_enabled)
    credentials = account |> Account.credentials_for_account()

    broadcast!(socket, "auth_credentials", %{
      credentials: credentials,
      user_info: user_info,
      verification_info: verification_info
    })
  end
end
