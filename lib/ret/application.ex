defmodule Ret.Application do
  use Application
  import Cachex.Spec

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec

    # Start application, start repos, take lock, run migrations, stop repos
    Application.load(:ret)
    EctoBootMigration.start_dependencies()

    repos_pids =
      Ret.Locking.exec_if_session_lockable("ret_migration", fn ->
        repos_pids = EctoBootMigration.start_repos([Ret.SessionLockRepo])

        # Note the main Repo database is used here, since the session locking database
        # name may be a proxy database in pgbouncer which doesn't actually exist.
        db_name = Application.get_env(:ret, Ret.Repo)[:database]

        # Can't check mix_env here, so check db name
        if db_name !== "ret_test" do
          coturn_enabled = Ret.Coturn.enabled?()

          Ecto.Adapters.SQL.query!(Ret.SessionLockRepo, "CREATE SCHEMA IF NOT EXISTS ret0")

          if coturn_enabled do
            Ecto.Adapters.SQL.query!(Ret.SessionLockRepo, "CREATE SCHEMA IF NOT EXISTS coturn")
          end

          Ecto.Adapters.SQL.query!(
            Ret.SessionLockRepo,
            "ALTER DATABASE #{db_name} SET search_path TO ret0"
          )

          priv_path = Path.join(["#{:code.priv_dir(:ret)}", "repo", "migrations"])

          # Disallow stop of the application via SIGTERM until migrations are finished.
          #
          # If application is killed mid-migration, then it's possible for schema migrations
          # table to not accurately reflect the migrations which have ran.
          Ret.DelayStopSignalHandler.delay_stop()

          try do
            Ecto.Migrator.run(Ret.SessionLockRepo, priv_path, :up, all: true, prefix: "ret0")
          after
            Ret.DelayStopSignalHandler.allow_stop()
          end

          repos_pids
        end
      end)

    if repos_pids do
      # Ensure there are some TURN secrets in the database, so that if system is idle
      # the cron isn't indefinitely skipped and nobody can join rooms.
      Ret.Coturn.rotate_secrets(true, Ret.SessionLockRepo)

      EctoBootMigration.stop_repos(repos_pids)
    end

    :ok = Ret.Statix.connect()

    # Define workers and child supervisors to be supervised
    children = [
      # Start the PubSub system
      {Phoenix.PubSub, [name: Ret.PubSub, adapter: Phoenix.PubSub.PG2, pool_size: 4]},

      # Start the Ecto repository
      supervisor(Ret.Repo, []),
      supervisor(RetWeb.Endpoint, []),
      supervisor(RetWeb.Presence, []),

      # Quantum scheduler
      worker(Ret.Scheduler, []),
      # Room assigner monitor
      worker(Ret.RoomAssignerMonitor, []),
      # Storage for rate limiting
      worker(PlugAttack.Storage.Ets, [RetWeb.RateLimit.Storage, [clean_period: 60_000]]),
      # Media resolution cache
      worker(
        Cachex,
        [
          :media_urls,
          [
            expiration: expiration(default: :timer.minutes(5)),
            fallback: fallback(default: &Ret.MediaResolver.resolve/1)
          ]
        ],
        id: :media_url_cache
      ),

      # Media search cache
      worker(
        Cachex,
        [
          :media_search_results,
          [
            expiration: expiration(default: :timer.minutes(5)),
            fallback: fallback(default: &Ret.MediaSearch.search/1)
          ]
        ],
        id: :media_search_cache
      ),

      # Long-lived media search cache, used for common queries that have quotas
      worker(
        Cachex,
        [
          :media_search_results_long,
          [
            expiration: expiration(default: :timer.hours(24)),
            fallback: fallback(default: &Ret.MediaSearch.search/1)
          ]
        ],
        id: :media_search_cache_long
      ),

      # Discord API cache
      worker(
        Cachex,
        [
          :discord_api,
          [
            expiration: expiration(default: :timer.minutes(1)),
            fallback: fallback(default: &Ret.DiscordClient.api_request/1)
          ]
        ],
        id: :discord_api_cache
      ),

      # Slack API cache
      worker(
        Cachex,
        [
          :slack_api,
          [
            expiration: expiration(default: :timer.minutes(1)),
            fallback: fallback(default: &Ret.SlackClient.api_request/1)
          ]
        ],
        id: :slack_api_cache
      ),

      # App Config cache
      worker(
        Cachex,
        [
          :app_config,
          [
            expiration: expiration(default: :timer.seconds(10)),
            fallback: fallback(default: &Ret.AppConfig.fetch_config/1)
          ]
        ],
        id: :app_config_cache
      ),

      # App Config value cache
      worker(
        Cachex,
        [
          :app_config_value,
          [
            expiration: expiration(default: :timer.seconds(15)),
            fallback: fallback(default: &Ret.AppConfig.get_config_value/1)
          ]
        ],
        id: :app_config_value_cache
      ),

      # App Config owned file uri cache
      worker(
        Cachex,
        [
          :app_config_owned_file_uri,
          [
            expiration: expiration(default: :timer.seconds(15)),
            fallback: fallback(default: &Ret.AppConfig.get_config_owned_file_uri/1)
          ]
        ],
        id: :app_config_owned_file_uri_cache
      ),

      # General asset cache
      worker(
        Cachex,
        [:assets, []],
        id: :asset_cache
      ),

      # Page origin chunk cache
      worker(
        Cachex,
        [
          :page_chunks,
          [
            warmers: [warmer(module: Ret.PageOriginWarmer)]
          ]
        ],
        id: :page_chunk_cache
      ),

      # Janus load status cache
      worker(
        Cachex,
        [
          :janus_load_status,
          [
            warmers: [warmer(module: Ret.JanusLoadStatus)]
          ]
        ],
        id: :janus_load_status
      ),

      # Storage used space cache
      worker(
        Cachex,
        [
          :storage_used,
          [
            warmers: [warmer(module: Ret.StorageUsed)]
          ]
        ],
        id: :storage_used
      ),

      # Latest TURN secret cache
      worker(
        Cachex,
        [
          :coturn_secret,
          [
            expiration: expiration(default: :timer.minutes(1)),
            fallback: fallback(default: &Ret.Coturn.latest_secret_commit/1)
          ]
        ],
        id: :coturn_secret
      ),
      supervisor(TheEnd.Of.Phoenix, [[timeout: 10_000, endpoint: RetWeb.Endpoint]])
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ret.Supervisor]
    :ok = :error_logger.add_report_handler(Sentry.Logger)
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    RetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
