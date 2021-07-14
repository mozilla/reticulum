# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
use Mix.Config

# General application configuration
config :ret, ecto_repos: [Ret.Repo, Ret.SessionLockRepo]

config :phoenix, :format_encoders, "json-api": Jason
config :phoenix, :json_library, Jason

config :canary,
  repo: Ret.Repo,
  unauthorized_handler: {RetWeb.Canary.AuthorizationErrorHandler, :authorization_error}

config :mime, :types, %{
  "application/vnd.api+json" => ["json-api"],
  "model/gltf+json" => ["gltf"],
  "model/gltf-binary" => ["glb"],
  "application/vnd.spoke.scene" => ["spoke"],
  "application/vnd.pgrst.object+json" => ["json"],
  "application/json" => ["json"],
  "application/wasm" => ["wasm"]
}

# Configures the endpoint
config :ret, RetWeb.Endpoint,
  url: [host: "localhost"],
  # This config value is for local development only.
  secret_key_base: "txlMOtlaY5x3crvOCko4uV5PM29ul3zGo1oBGNO3cDXx+7GHLKqt0gR9qzgThxb5",
  render_errors: [view: RetWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Ret.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :ret, Ret.Repo,
  migration_source: "schema_migrations",
  migration_default_prefix: "ret0",
  after_connect: {Ret.Repo, :set_search_path, ["public, ret0"]},
  # Downloads from Sketchfab to file cache hold connections open
  ownership_timeout: 60_000,
  timeout: 60_000

config :ret, Ret.SessionLockRepo,
  migration_source: "schema_migrations",
  migration_default_prefix: "ret0",
  after_connect: {Ret.SessionLockRepo, :set_search_path, ["public, ret0"]},
  # Downloads from Sketchfab to file cache hold connections open
  ownership_timeout: 60_000,
  timeout: 60_000

config :peerage, log_results: false

config :statix, prefix: "ret"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
