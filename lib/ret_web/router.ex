defmodule RetWeb.Router do
  use RetWeb, :router
  use Plug.ErrorHandler
  use Sentry.Plug

  secure? =
    :ret
    |> Application.compile_env!(__MODULE__)
    |> Keyword.fetch!(:secure?)

  pipeline :secure_headers do
    plug :put_secure_browser_headers
    plug RetWeb.Plugs.AddCSP
  end

  pipeline :strict_secure_headers do
    plug :put_secure_browser_headers
    plug RetWeb.Plugs.AddCSP, strict: true
  end

  pipeline :ssl_only do
    plug Plug.SSL, hsts: true, rewrite_on: [:x_forwarded_proto]
  end

  pipeline :parsed_body do
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 157_286_400,
      read_timeout: 300_000
  end

  pipeline :rate_limit do
    plug RetWeb.Plugs.RateLimit
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_layout, false
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :public_api_access do
    plug RetWeb.Plugs.RequirePublicApiAccess
  end

  pipeline :proxy_api do
    plug :accepts, ["json"]
    plug RetWeb.Plugs.RewriteAuthorizationHeaderToPerms
  end

  pipeline :auth_optional do
    plug RetWeb.Guardian.AuthOptionalPipeline
  end

  pipeline :forbid_disabled_accounts do
    plug RetWeb.Plugs.ForbidDisabledAccounts
  end

  pipeline :auth_required do
    plug RetWeb.Guardian.AuthPipeline
    plug RetWeb.Canary.AuthorizationPipeline
    plug RetWeb.Plugs.ForbidDisabledAccounts
  end

  pipeline :admin_required do
    plug RetWeb.Guardian.AuthPipeline
    plug RetWeb.Plugs.AdminOnly
    plug RetWeb.Plugs.ForbidDisabledAccounts
  end

  pipeline :bot_header_auth do
    plug RetWeb.Plugs.BotHeaderAuthorization
  end

  pipeline :dashboard_header_auth do
    plug RetWeb.Plugs.DashboardHeaderAuthorization
  end

  pipeline :canonicalize_domain do
    plug RetWeb.Plugs.RedirectToMainDomain
  end

  pipeline :graphql do
    plug(RetWeb.ApiTokenAuthPipeline)
    plug(RetWeb.AddAbsintheContext)
  end

  scope "/health", RetWeb do
    get "/", HealthController, :index
  end

  scope "/api/postgrest" do
    pipe_through [:secure_headers, :auth_required, :admin_required, :proxy_api]

    forward "/", RetWeb.Plugs.PostgrestProxy
  end

  scope "/api/ita" do
    pipe_through [:secure_headers, :auth_required, :admin_required, :proxy_api]

    forward "/", RetWeb.Plugs.ItaProxy
  end

  scope "/api", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :api] ++
                   if(secure?, do: [:ssl_only, :canonicalize_domain], else: [])

    scope "/v1", as: :api_v1 do
      get "/meta", Api.V1.MetaController, :show
      get "/avatars/:id/base.gltf", Api.V1.AvatarController, :show_base_gltf
      get "/avatars/:id/avatar.gltf", Api.V1.AvatarController, :show_avatar_gltf
      get "/oauth/:type", Api.V1.OAuthController, :show

      scope "/support" do
        resources "/subscriptions", Api.V1.SupportSubscriptionController, only: [:create, :delete]
        resources "/availability", Api.V1.SupportSubscriptionController, only: [:index]
      end

      resources "/credentials/scopes", Api.V1.ScopesController, only: [:index]
      resources "/ret_notices", Api.V1.RetNoticeController, only: [:create]

      get "/whats-new", Api.V1.WhatsNewController, :show
    end

    scope "/v1", as: :api_v1 do
      resources "/slack", Api.V1.SlackController, only: [:create]
    end

    scope "/v1", as: :api_v1 do
      pipe_through [:bot_header_auth]

      resources "/hub_bindings", Api.V1.HubBindingController, only: [:create]
    end

    scope "/v1", as: :api_v1 do
      pipe_through [:auth_optional, :forbid_disabled_accounts]

      resources "/hubs", Api.V1.HubController, only: [:create, :delete]
    end

    # Must be defined before :show for scenes
    scope "/v1", as: :api_v1 do
      pipe_through [:auth_required]

      get "/scenes/projectless", Api.V1.SceneController, :index_projectless
    end

    scope "/v1", as: :api_v1 do
      pipe_through [:auth_optional]

      resources "/media/search", Api.V1.MediaSearchController, only: [:index]
      resources "/avatars", Api.V1.AvatarController, only: [:show]
      resources "/scenes", Api.V1.SceneController, only: [:show]
    end

    scope "/v1", as: :api_v1 do
      pipe_through [:auth_required]

      resources "/scenes", Api.V1.SceneController, only: [:create, :update]
      resources "/avatars", Api.V1.AvatarController, only: [:create, :update, :delete]
      resources "/hubs", Api.V1.HubController, only: [:update]
      resources "/assets", Api.V1.AssetsController, only: [:create, :delete]

      post "/twitter/tweets", Api.V1.TwitterController, :tweets

      resources "/projects", Api.V1.ProjectController,
        only: [:index, :show, :create, :update, :delete] do
        post "/publish", Api.V1.ProjectController, :publish

        resources "/assets", Api.V1.ProjectAssetsController, only: [:index, :create, :delete]
      end
    end

    scope "/v1", as: :api_v1 do
      pipe_through [:admin_required]

      resources "/app_configs", Api.V1.AppConfigController, only: [:index, :create]
      resources "/accounts", Api.V1.AccountController, only: [:create, :delete]
      patch "/accounts", Api.V1.AccountController, :update
      resources "/accounts/search", Api.V1.AccountSearchController, only: [:create]
    end
  end

  scope "/api/v2_alpha", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :api, :public_api_access, :auth_required] ++
                   if(secure?, do: [:ssl_only, :canonicalize_domain], else: [])

    resources "/credentials", Api.V2.CredentialsController,
      only: [:create, :index, :update, :show]
  end

  scope "/api/v2_alpha", as: :api_v2_alpha do
    pipe_through [:parsed_body, :api, :public_api_access, :graphql] ++
                   if(secure?, do: [:ssl_only], else: [])

    forward("/graphiql", Absinthe.Plug.GraphiQL, json_codec: Jason, schema: RetWeb.Schema)
    forward("/", Absinthe.Plug, json_codec: Jason, schema: RetWeb.Schema)
  end

  scope "/api-internal", RetWeb do
    pipe_through [:dashboard_header_auth, :secure_headers, :parsed_body, :api] ++
                   if(secure?, do: [:ssl_only], else: [])

    scope "/v1", as: :api_internal_v1 do
      get "/presence", ApiInternal.V1.PresenceController, :show
      get "/presence/range_max", ApiInternal.V1.PresenceController, :range_max
      get "/storage", ApiInternal.V1.StorageController, :show
      post "/rewrite_assets", ApiInternal.V1.RewriteAssetsController, :post
      put "/change_email_for_login", ApiInternal.V1.LoginEmailController, :update
      post "/make_auth_token_for_email", ApiInternal.V1.AuthTokenController, :post
      get("/hub_stats", ApiInternal.V1.HubStatsController, :show)
    end
  end

  # Directly accessible APIs.
  # Permit direct file uploads without intermediate ALB/Cloudfront/CDN proxying.
  scope "/api", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :api] ++ if(secure?, do: [:ssl_only], else: [])

    scope "/v1", as: :api_v1 do
      resources "/media", Api.V1.MediaController, only: [:create]
    end
  end

  scope "/", RetWeb do
    pipe_through [:strict_secure_headers, :parsed_body, :browser] ++
                   if(secure?, do: [:ssl_only], else: [])

    head "/files/:id", FileController, :head
    get "/files/:id", FileController, :show
  end

  scope "/", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :browser] ++
                   if(secure?, do: [:ssl_only, :canonicalize_domain], else: [])

    get "/link", PageController, only: [:index]
  end

  scope "/", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :browser, :rate_limit] ++
                   if(secure?, do: [:ssl_only, :canonicalize_domain], else: [])

    get "/link/*path", PageController, only: [:index]
  end

  scope "/", RetWeb do
    pipe_through [:secure_headers, :parsed_body, :browser] ++
                   if(secure?, do: [:ssl_only, :canonicalize_domain], else: [])

    get "/*path", PageController, only: [:index]
  end
end
