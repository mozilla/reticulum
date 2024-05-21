defmodule RetWeb.ApiInternal.V1.AuthTokenController do
  require Logger

  use RetWeb, :controller

  def post(conn, %{"email" => email}) when is_binary(email) do
    {:ok, token, _params} =
      if !System.get_env("TURKEY_MODE") do
        {:ok, "-", nil}
      else
        email
        |> Ret.Account.find_or_create_account_for_email()
        |> Ret.Guardian.encode_and_sign()
      end

    send_resp(conn, 200, token)
  end
end
