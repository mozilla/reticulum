defmodule RetWeb.PageController do
  use RetWeb, :controller

  alias Ret.{
    Repo,
    Hub,
    Scene,
    SceneListing,
    Avatar,
    AppConfig,
    OwnedFile,
    AvatarListing,
    PageOriginWarmer,
    Storage,
    HttpUtils
  }

  alias Plug.Conn
  import Ret.ConnUtils

  ##
  # NOTE: In addition to adding a route, you must add static html pages to the page_origin_warmer.ex
  # file in order for them to work.
  ##

  @configurable_assets %{
    app_config_favicon: {"favicon.ico", "images|favicon", "image/x-icon"},
    app_config_app_icon: {"app-icon.png", "images|app_icon", "image/png"},
    app_config_app_thumbnail: {"app-thumbnail.png", "images|app_thumbnail", "image/png"}
  }

  @configurable_asset_files @configurable_assets |> Map.values() |> Enum.map(&elem(&1, 0))
  @configurable_asset_paths @configurable_asset_files |> Enum.map(&"/#{&1}")

  def call(conn, _params) do
    assets_host = RetWeb.Endpoint.config(:assets_url)[:host]
    link_host = RetWeb.Endpoint.config(:link_url)[:host]
    is_configurable_asset = @configurable_asset_paths |> Enum.any?(&(&1 === conn.request_path))

    cond do
      matches_host(conn, assets_host) && !is_configurable_asset ->
        render_asset(conn)

      matches_host(conn, link_host) ->
        case conn.request_path do
          "/" -> conn |> redirect(external: "#{RetWeb.Endpoint.url()}/link")
          _ -> conn |> redirect(external: "#{RetWeb.Endpoint.url()}/link#{conn.request_path}")
        end

      true ->
        case conn.request_path do
          "/docs" -> conn |> redirect(to: "/docs/welcome.html")
          "/docs/" -> conn |> redirect(to: "/docs/welcome.html")
          "/docs" <> _ -> render_docs(conn)
          "/thumbnail/" <> _ -> imgproxy_proxy(conn)
          "/http://" <> _ -> cors_proxy(conn)
          "/https://" <> _ -> cors_proxy(conn)
          _ -> render_for_path(conn.request_path, conn.query_params, conn)
        end
    end
  end

  defp render_scene_content(%t{} = scene, conn) when t in [Scene, SceneListing] do
    {app_config, app_config_script} = generate_app_config()

    scene_meta_tags =
      Phoenix.View.render_to_string(RetWeb.PageView, "scene-meta.html",
        scene: scene,
        ret_meta: Ret.Meta.get_meta(include_repo: false),
        translations: app_config["translations"]["en"],
        app_config_script: {:safe, app_config_script |> with_script_tags},
        extra_script: {:safe, get_extra_script(:scene) |> with_script_tags},
        extra_html: {:safe, get_extra_html(:scene) || ""}
      )

    case try_chunks_for_page(conn, "scene.html", :hubs) do
      {:ok, chunks} ->
        chunks_with_meta = chunks |> List.insert_at(1, scene_meta_tags)

        conn
        |> append_script_csp(app_config_script)
        |> append_extra_script_csp(:scene)
        |> put_hub_headers("scene")
        |> put_extra_response_headers_for_page(:scene)
        |> render_chunks(chunks_with_meta, "text/html; charset=utf-8")

      {:error, conn} ->
        conn
    end
  end

  defp render_scene_content(nil, conn) do
    conn |> send_resp(404, "")
  end

  defp render_avatar_content(%t{} = avatar, conn) when t in [Avatar, AvatarListing] do
    {app_config, app_config_script} = generate_app_config()

    avatar_meta_tags =
      Phoenix.View.render_to_string(RetWeb.PageView, "avatar-meta.html",
        avatar: avatar,
        ret_meta: Ret.Meta.get_meta(include_repo: false),
        translations: app_config["translations"]["en"],
        app_config_script: {:safe, app_config_script |> with_script_tags},
        extra_script: {:safe, get_extra_script(:avatar) |> with_script_tags},
        extra_html: {:safe, get_extra_html(:avatar) || ""}
      )

    case try_chunks_for_page(conn, "avatar.html", :hubs) do
      {:ok, chunks} ->
        chunks_with_meta = chunks |> List.insert_at(1, avatar_meta_tags)

        conn
        |> append_script_csp(app_config_script)
        |> append_extra_script_csp(:avatar)
        |> put_hub_headers("avatar")
        |> put_extra_response_headers_for_page(:avatar)
        |> render_chunks(chunks_with_meta, "text/html; charset=utf-8")

      {:error, conn} ->
        conn
    end
  end

  defp render_avatar_content(nil, conn) do
    conn |> send_resp(404, "")
  end

  defp render_homepage_content(conn, nil = _public_room_id) do
    {app_config, app_config_script} = generate_app_config()

    index_meta_tags =
      Phoenix.View.render_to_string(
        RetWeb.PageView,
        "index-meta.html",
        root_url: RetWeb.Endpoint.url(),
        translations: app_config["translations"]["en"],
        app_config_script: {:safe, app_config_script |> with_script_tags},
        extra_script: {:safe, get_extra_script(:index) |> with_script_tags},
        extra_html: {:safe, get_extra_html(:index) || ""}
      )

    case try_chunks_for_page(conn, "index.html", :hubs) do
      {:ok, chunks} ->
        chunks_with_meta = chunks |> List.insert_at(1, index_meta_tags)

        conn
        |> append_script_csp(app_config_script)
        |> append_extra_script_csp(:index)
        |> put_hub_headers("hub")
        |> put_extra_response_headers_for_page(:index)
        |> render_chunks(chunks_with_meta, "text/html; charset=utf-8")

      {:error, conn} ->
        conn
    end
  end

  # Allow loading homepage if auth_token is being used to log in
  defp render_homepage_content(
         %Plug.Conn{query_params: %{"auth_token" => _auth_token}} = conn,
         _default_room_id
       ),
       do: render_homepage_content(conn, nil)

  defp render_homepage_content(conn, default_room_id) do
    hub = Hub |> Repo.get_by(hub_sid: default_room_id)
    conn |> render_hub_content(hub, "homepage")
  end

  def render_for_path("/", params, conn) do
    if !Enum.empty?(params) || Ret.Account.has_accounts?() do
      conn |> render_index
    else
      conn |> redirect(to: "/admin")
    end
  end

  def render_for_path("/scenes/" <> path, _params, conn) do
    path
    |> String.split("/")
    |> Enum.at(0)
    |> Scene.scene_or_scene_listing_by_sid()
    |> Repo.preload([:screenshot_owned_file])
    |> render_scene_content(conn)
  end

  def render_for_path("/avatars/" <> path, _params, conn) do
    path
    |> String.split("/")
    |> Enum.at(0)
    |> Avatar.avatar_or_avatar_listing_by_sid()
    |> Repo.preload([:thumbnail_owned_file])
    |> render_avatar_content(conn)
  end

  def render_for_path("/link", _params, conn),
    do:
      conn
      |> put_hub_headers("hub")
      |> render_page("link.html", :hubs, "link-meta.html")

  def render_for_path("/link/", _params, conn),
    do:
      conn
      |> put_hub_headers("hub")
      |> render_page("link.html", :hubs, "link-meta.html")

  def render_for_path("/link/" <> hub_sid_and_slug, _params, conn) do
    hub_sid = hub_sid_and_slug |> String.split("/") |> List.first()

    conn
    |> put_hub_headers("link")
    |> redirect_to_hub_sid(hub_sid)
  end

  def render_for_path("/signin", _params, conn), do: conn |> render_page("signin.html")
  def render_for_path("/signin/", _params, conn), do: conn |> render_page("signin.html")

  def render_for_path("/verify", _params, conn), do: conn |> render_page("verify.html")
  def render_for_path("/verify/", _params, conn), do: conn |> render_page("verify.html")

  def render_for_path("/tokens", _params, conn), do: conn |> render_page("tokens.html")
  def render_for_path("/tokens/", _params, conn), do: conn |> render_page("tokens.html")

  def render_for_path("/discord", _params, conn), do: conn |> render_page("discord.html")
  def render_for_path("/discord/", _params, conn), do: conn |> render_page("discord.html")

  def render_for_path("/cloud", _params, conn), do: conn |> render_page("cloud.html")
  def render_for_path("/cloud/", _params, conn), do: conn |> render_page("cloud.html")

  def render_for_path("/spoke", _params, conn),
    do: conn |> render_page("index.html", :spoke, "spoke-index-meta.html")

  def render_for_path("/spoke/" <> _path, _params, conn),
    do: conn |> render_page("index.html", :spoke, "spoke-index-meta.html")

  def render_for_path("/whats-new", _params, conn),
    do: conn |> render_page("whats-new.html", :hubs, "whats-new-meta.html")

  def render_for_path("/whats-new/", _params, conn),
    do: conn |> render_page("whats-new.html", :hubs, "whats-new-meta.html")

  def render_for_path("/hub.service.js", _params, conn),
    do: conn |> render_asset("hub.service.js", :hubs, "hub.service-meta.js")

  def render_for_path("/stream-offline.png", _params, conn), do: conn |> render_static_asset()
  def render_for_path("/quota-error.png", _params, conn), do: conn |> render_static_asset()

  def render_for_path("/hubs/schema.toml", _params, conn), do: conn |> render_asset("schema.toml")

  def render_for_path("/manifest.webmanifest", _params, conn) do
    ua =
      conn
      |> Conn.get_req_header("user-agent")
      |> List.first()
      |> UAParser.parse()

    # For iOS, do not render the manifest since we don't want to trigger the PWA functionality,
    # since WebRTC doesn't work then.
    supports_pwa = ua.family != "Safari" && ua.family != "Mobile Safari"

    if supports_pwa do
      manifest =
        case Cachex.get(:assets, :manifest) do
          {:ok, nil} ->
            manifest =
              Phoenix.View.render_to_string(RetWeb.PageView, "manifest.webmanifest",
                root_url: RetWeb.Endpoint.url(),
                app_name: get_app_config_value("translations|en|app-name") || "",
                app_description:
                  (get_app_config_value("translations|en|app-description") || "")
                  |> String.replace("\\n", " ")
              )

            unless module_config(:skip_cache) do
              Cachex.put(:assets, :manifest, manifest, ttl: :timer.seconds(15))
            end

            manifest

          {:ok, manifest} ->
            manifest
        end

      conn
      |> put_resp_header("content-type", "application/manifest+json")
      |> send_resp(200, manifest)
    else
      conn |> send_resp(404, "Not found.")
    end
  end

  def render_for_path("/" <> file, _params, conn) when file in @configurable_asset_files do
    {asset_key, {_file, path, mime_type}} =
      @configurable_assets
      |> Enum.find(fn {_, {f, _, _}} -> f === file end)

    conn |> respond_with_configurable_asset(asset_key, path, mime_type)
  end

  def render_for_path("/admin", _params, conn) do
    conn |> render_page("admin.html", :admin)
  end

  def render_for_path("/robots.txt", _params, conn) do
    allow_crawlers = Application.get_env(:ret, RetWeb.Endpoint)[:allow_crawlers] || false

    robots_txt =
      Phoenix.View.render_to_string(RetWeb.PageView, "robots.txt", allow_crawlers: allow_crawlers)

    conn
    |> send_resp(200, robots_txt)
  end

  def render_for_path("/" <> path, params, conn) do
    embed_token = params["embed_token"]

    [hub_sid | subresource] = path |> String.split("/")

    hub = Hub |> Repo.get_by(hub_sid: hub_sid)

    if embed_token && hub.embed_token != embed_token do
      conn |> send_resp(404, "Invalid embed token.")
    else
      conn =
        if embed_token do
          # Allow iframe embedding
          conn |> delete_resp_header("x-frame-options")
        else
          conn
        end

      render_hub_content(conn, hub, subresource |> Enum.at(0))
    end
  end

  defp respond_with_configurable_asset(conn, cache_key, config_key, content_type) do
    asset =
      case Cachex.get(:assets, cache_key) do
        {:ok, nil} ->
          app_config = AppConfig |> Repo.get_by(key: config_key) |> Repo.preload(:owned_file)

          asset =
            with %AppConfig{owned_file: %OwnedFile{} = owned_file} <- app_config,
                 {:ok, _meta, stream} <- Storage.fetch(owned_file) do
              stream |> Enum.join("")
            else
              _ -> ""
            end

          unless module_config(:skip_cache) do
            Cachex.put(:assets, cache_key, asset, ttl: :timer.seconds(15))
          end

          asset

        {:ok, asset} ->
          asset
      end

    if asset === "" do
      conn
      |> send_resp(404, "")
    else
      conn
      |> put_resp_header("content-type", content_type)
      |> send_resp(200, asset)
    end
  end

  defp render_index(conn) do
    method = conn |> get_req_header("x-original-method") |> Enum.at(0)
    conn |> render_index(method)
  end

  defp render_index(conn, "HEAD") do
    conn
    |> put_hub_headers("hub")
    |> send_resp(200, "")
  end

  defp render_index(conn, _method) do
    conn |> render_homepage_content(get_app_config_value("features|default_room_id"))
  end

  defp put_hub_headers(conn, entity_type) do
    conn
    |> put_resp_header(
      "hub-name",
      get_app_config_value("translations|en|app-full-name") ||
        get_app_config_value("translations|en|app-name") || ""
    )
    |> put_resp_header(
      "hub-entity-type",
      entity_type
    )
  end

  defp get_app_config_value(key) do
    if module_config(:skip_cache) do
      AppConfig.get_config_value(key)
    else
      AppConfig.get_cached_config_value(key)
    end
  end

  defp append_csp(conn, directive, source) do
    csp_header =
      conn.resp_headers |> Enum.find(fn {key, _value} -> key == "content-security-policy" end)

    new_directive = "#{directive} #{source}"

    csp_value =
      case csp_header do
        nil ->
          new_directive

        {_csp, csp_value} ->
          if csp_value |> String.contains?(directive) do
            csp_value |> String.replace(directive, new_directive)
          else
            "#{csp_value}; #{new_directive};"
          end
      end

    conn |> put_resp_header("content-security-policy", csp_value)
  end

  def render_hub_content(conn, nil, _) do
    conn |> send_resp(200, "ERR: Room ID not valid. Please contact your Hub administrator")
  end

  def render_hub_content(conn, hub, "objects.gltf") do
    room_gltf = hub.hub_id |> Ret.RoomObject.gltf_for_hub_id() |> Poison.encode!()

    conn
    |> put_resp_header("content-type", "model/gltf+json; charset=utf-8")
    |> send_resp(200, room_gltf)
  end

  def render_hub_content(conn, hub, _slug) do
    hub =
      hub
      |> Repo.preload(scene: [:screenshot_owned_file], scene_listing: [:screenshot_owned_file])

    {app_config, app_config_script} = generate_app_config()

    {_, available_integrations_script} =
      Ret.Meta.available_integrations_meta() |> generate_config("AVAILABLE_INTEGRATIONS")

    hub_meta_tags =
      Phoenix.View.render_to_string(RetWeb.PageView, "hub-meta.html",
        hub: hub,
        scene: hub.scene,
        ret_meta: Ret.Meta.get_meta(include_repo: false),
        available_integrations_script: {:safe, available_integrations_script |> with_script_tags},
        translations: app_config["translations"]["en"],
        app_config_script: {:safe, app_config_script |> with_script_tags},
        extra_script: {:safe, get_extra_script(:room) |> with_script_tags},
        extra_html: {:safe, get_extra_html(:room) || ""}
      )

    case try_chunks_for_page(conn, "hub.html", :hubs) do
      {:ok, chunks} ->
        chunks_with_meta = chunks |> List.insert_at(1, hub_meta_tags)

        conn
        |> append_script_csp(app_config_script)
        |> append_script_csp(available_integrations_script)
        |> append_extra_script_csp(:room)
        |> put_hub_headers("room")
        |> put_extra_response_headers_for_page(:room)
        |> render_chunks(chunks_with_meta, "text/html; charset=utf-8")

      {:error, conn} ->
        conn
    end
  end

  def generate_app_config() do
    Ret.AppConfig.get_config(!!module_config(:skip_cache)) |> generate_config("APP_CONFIG")
  end

  # We receive the themes array as stringified JSON. We must decode it here and
  # then re-encode it so that it will be successfully parsed by the client.
  #
  # The data going into this function looks something like this:
  # %{
  #   "theme" => %{
  #     "themes" => "[
  #       { \"id\": \"theme-1\", ...},
  #       { \"id\": \"theme-2\", ...},
  #       ...
  #     ]",
  #     "deprecated_color_property_1" => "#ffffff",
  #     "deprecated_color_property_n" => "#000000"
  #   }
  # }
  # The data returned from this function looks something like this:
  # %{
  #   "theme" => %{
  #     "themes" => [
  #       %{ "id" => "theme-1", ...},
  #       %{ "id" => "theme-2", ...},
  #       ...
  #     ],
  #     "deprecated_color_property_1" => "#ffffff",
  #     "deprecated_color_property_n" => "#000000"
  #   }
  # }
  defp escape_themes(%{"theme" => %{"themes" => string} = category} = config) do
    case Poison.decode(string || "") do
      {:ok, array} ->
        Map.put(config, "theme", Map.put(category, "themes", array))

      _ ->
        category = Map.put(category, "themes", [])
        category = Map.put(category, "error", "Failed to parse custom theme JSON.")
        Map.put(config, "theme", category)
    end
  end

  defp escape_themes(config) do
    config
  end

  defp generate_config(config, name) do
    config_json = config |> escape_themes() |> Poison.encode!()
    config_script = "window.#{name} = JSON.parse('#{config_json |> String.replace("'", "\\'")}')"
    {config, config_script}
  end

  defp csp_for_script(script), do: "'sha256-#{:crypto.hash(:sha256, script) |> :base64.encode()}'"

  defp redirect_to_hub_sid(conn, hub_sid) do
    hub = Repo.get_by(Hub, hub_sid: hub_sid)

    case hub do
      %Hub{} = hub -> conn |> redirect(to: "/#{hub.hub_sid}/#{hub.slug}")
      _ -> conn |> send_resp(404, "")
    end
  end

  defp render_asset(conn, asset, source \\ :hubs, meta_template \\ nil)

  defp render_asset(conn, nil, _source, _meta_template) do
    conn |> send_resp(404, "")
  end

  defp render_asset(conn, asset, source, meta_template) do
    app_config = Ret.AppConfig.get_config(!!module_config(:skip_cache))

    meta_content =
      if meta_template do
        Phoenix.View.render_to_string(RetWeb.PageView, meta_template,
          translations: app_config["translations"]["en"]
        )
      else
        []
      end

    case try_chunks_for_page(conn, asset, source) do
      {:ok, chunks} ->
        chunks_with_meta = chunks |> List.insert_at(1, meta_content)
        conn |> render_chunks(chunks_with_meta, asset |> content_type_for_page)

      {:error, conn} ->
        conn
    end
  end

  defp render_page(conn, page, source \\ :hubs, meta_template \\ nil)

  defp render_page(conn, nil, _source, _meta_template) do
    conn |> send_resp(404, "")
  end

  defp render_page(conn, page, source, meta_template) do
    {app_config, app_config_script} = generate_app_config()

    meta_tags =
      if meta_template do
        Phoenix.View.render_to_string(RetWeb.PageView, meta_template,
          translations: app_config["translations"]["en"]
        )
      else
        []
      end

    case try_chunks_for_page(conn, page, source) do
      {:ok, chunks} ->
        chunks_with_meta =
          chunks
          |> List.insert_at(1, app_config_script |> with_script_tags)
          |> List.insert_at(1, meta_tags)

        conn
        |> append_script_csp(app_config_script)
        |> render_chunks(chunks_with_meta, page |> content_type_for_page)

      {:error, conn} ->
        conn
    end
  end

  defp try_chunks_for_page(conn, page, source) do
    res =
      if module_config(:skip_cache) do
        PageOriginWarmer.chunks_for_page(source, page)
      else
        Cachex.get(:page_chunks, {source, page})
      end

    case res do
      {:ok, chunks} = res when chunks != nil -> res
      _ -> {:error, conn |> send_resp(503, "Missing file #{page}. Please try again.")}
    end
  end

  defp content_type_for_page("hub.service.js"), do: "application/javascript; charset=utf-8"
  defp content_type_for_page("schema.toml"), do: "text/plain"
  defp content_type_for_page(_), do: "text/html; charset=utf-8"

  defp render_chunks(conn, chunks, content_type) do
    conn
    |> put_resp_header("content-type", content_type)
    |> send_resp(200, chunks |> List.flatten() |> Enum.join("\n"))
  end

  defp imgproxy_proxy(%Conn{request_path: "/thumbnail/" <> encoded_url, query_string: qs} = conn) do
    with imgproxy_url <- Application.get_env(:ret, RetWeb.Endpoint)[:imgproxy_url],
         [scheme, port, host] =
           [:scheme, :port, :host] |> Enum.map(&Keyword.get(imgproxy_url, &1)),
         %{"w" => width, "h" => height} <- qs |> URI.decode_query() do
      thumbnail_url = "#{scheme}://#{host}:#{port}//auto/#{width}/#{height}/sm/1/#{encoded_url}"

      opts =
        ReverseProxyPlug.init(
          upstream: thumbnail_url,
          client_options: [ssl: [{:versions, [:"tlsv1.2"]}]]
        )

      body = ReverseProxyPlug.read_body(conn)

      %Conn{}
      |> Map.merge(conn)
      # Need to strip path_info since proxy plug reads it
      |> Map.put(:path_info, [])
      |> ReverseProxyPlug.request(body, opts)
      |> ReverseProxyPlug.response(conn, opts)
    else
      _ ->
        conn |> send_resp(401, "Bad request")
    end
  end

  defp cors_proxy(%Conn{request_path: "/" <> url, query_string: ""} = conn),
    do: cors_proxy(conn, url)

  defp cors_proxy(%Conn{request_path: "/" <> url, query_string: qs} = conn),
    do: cors_proxy(conn, "#{url}?#{qs}")

  defp cors_proxy(conn, url) do
    %URI{authority: authority, host: host} = uri = URI.parse(url)

    resolved_ip = HttpUtils.resolve_ip(host)

    if HttpUtils.internal_ip?(resolved_ip) do
      conn |> send_resp(401, "Bad request.")
    else
      # We want to ensure that the URL we request hits the same IP that we verified above,
      # so we replace the host with the IP address here and use this url to make the proxy request.
      ip_url = URI.to_string(HttpUtils.replace_host(uri, resolved_ip))

      # Disallow CORS proxying unless request was made to the cors proxy url
      cors_proxy_url = Application.get_env(:ret, RetWeb.Endpoint)[:cors_proxy_url]

      [cors_scheme, cors_port, cors_host] =
        [:scheme, :port, :host] |> Enum.map(&Keyword.get(cors_proxy_url, &1))

      is_cors_proxy_url =
        cors_scheme == Atom.to_string(conn.scheme) && cors_host == conn.host &&
          cors_port == conn.port

      if is_cors_proxy_url do
        allowed_origins =
          Application.get_env(:ret, RetWeb.Endpoint)[:allowed_origins] |> String.split(",")

        opts =
          ReverseProxyPlug.init(
            upstream: ip_url,
            allowed_origins: allowed_origins,
            proxy_url: "#{cors_scheme}://#{cors_host}:#{cors_port}",
            # Since we replaced the host with the IP address in ip_url above, we need to force the host
            # used for ssl verification here so that the connection isn't rejected.
            # Note that we have to convert the authority to a charlist, since this uses Erlang's `ssl` module
            # internally, which expects a charlist.
            client_options: [
              ssl: [{:server_name_indication, to_charlist(authority)}, {:versions, [:"tlsv1.2"]}]
            ],
            preserve_host_header: true
          )

        body = ReverseProxyPlug.read_body(conn)
        is_head = conn |> Conn.get_req_header("x-original-method") == ["HEAD"]

        %Conn{}
        |> Map.merge(conn)
        |> Map.put(
          :method,
          if is_head do
            "HEAD"
          else
            conn.method
          end
        )
        # Need to strip path_info since proxy plug reads it
        |> Map.put(:path_info, [])
        # Since we replaced the host with the IP address in ip_url above, we need to force the host
        # header back to the original authority so that the proxy destination does not reject our request
        |> Map.update!(:req_headers, &[{"host", authority} | &1])
        # Some domains disallow access from improper Origins
        |> Conn.delete_req_header("origin")
        |> ReverseProxyPlug.request(body, opts)
        |> ReverseProxyPlug.response(conn, opts)
      else
        conn |> send_resp(401, "Bad request.")
      end
    end
  end

  defp render_static_asset(conn) do
    static_options = Plug.Static.init(at: "/", from: :ret, gzip: true, brotli: true)
    Plug.Static.call(conn, static_options)
  end

  defp render_asset(conn) do
    static_options =
      Plug.Static.init(at: "/", from: module_config(:assets_path), gzip: true, brotli: true)

    Plug.Static.call(conn, static_options)
  end

  defp render_docs(conn) do
    static_options =
      Plug.Static.init(at: "/docs", from: module_config(:docs_path), gzip: true, brotli: true)

    Plug.Static.call(conn, static_options)
  end

  defp put_extra_response_headers_for_page(conn, key) do
    conn |> put_extra_response_headers(module_config(:"extra_#{key}_headers") || "")
  end

  defp put_extra_response_headers(conn, nil), do: conn
  defp put_extra_response_headers(conn, ""), do: conn

  defp put_extra_response_headers(conn, value) do
    value
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&extra_header_to_tuple/1)
    |> Enum.reduce(conn, fn {name, value}, conn -> conn |> put_resp_header(name, value) end)
  end

  defp extra_header_to_tuple(header) do
    [name | value] = header |> String.split(~r/:\s*/, parts: 2) |> Enum.map(&String.trim/1)

    name =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "")

    {name, value |> Enum.join("")}
  end

  defp append_extra_script_csp(conn, key) do
    case module_config(:"extra_#{key}_script") do
      nil -> conn
      script -> conn |> append_script_csp(script)
    end
  end

  defp get_extra_script(key), do: module_config(:"extra_#{key}_script")
  defp get_extra_html(key), do: module_config(:"extra_#{key}_html")

  defp append_script_csp(conn, nil), do: conn
  defp append_script_csp(conn, ""), do: conn

  defp append_script_csp(conn, script),
    do: conn |> append_csp("script-src", csp_for_script(script))

  defp with_script_tags(nil), do: ""
  defp with_script_tags(""), do: ""
  defp with_script_tags(script), do: "<script>#{script}</script>"

  defp module_config(key), do: Application.get_env(:ret, __MODULE__)[key]
end
