defmodule Ret.RemoteOIDCToken do
  @moduledoc """
  This represents an OpenID Connect token returned from a remote service.
  These tokens are never created locally, only ever provided externally and verified locally.
  """
  use Guardian,
    otp_app: :ret,
    secret_fetcher: Ret.RemoteOIDCTokenSecretsFetcher

  def subject_for_token(_, _), do: {:ok, nil}
  def resource_from_claims(_), do: {:ok, nil}
end

defmodule Ret.RemoteOIDCTokenSecretsFetcher do
  @moduledoc """
  This represents the public keys for an OpenID Connect endpoint used to verify tokens.
  The public keys will be configured by an admin for a particular setup. These can not be used for signing.
  """

  def fetch_signing_secret(_mod, _opts) do
    {:error, :not_implemented}
  end

  def fetch_verifying_secret(mod, %{"kid" => kid, "typ" => "JWT"}, _opts) do
    # TODO implement read through cache that hits discovery endpoint instead of hardcoding keys in config as per https://openid.net/specs/openid-connect-core-1_0.html#RotateSigKeys
    case Application.get_env(:ret, mod)[:verification_secret_jwk_set]
         |> Poison.decode!()
         |> Map.get("keys")
         |> Enum.find(&(Map.get(&1, "kid") == kid)) do
      nil -> {:error, :invalid_key_id}
      key -> {:ok, key |> JOSE.JWK.from_map()}
    end
  end

  def fetch_verifying_secret(_mod, _token_headers_, _optss) do
    {:error, :invalid_token}
  end
end
