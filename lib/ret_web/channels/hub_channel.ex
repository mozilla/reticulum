defmodule RetWeb.HubChannel do
  @moduledoc "Ret Web Channel for Hubs"

  use RetWeb, :channel

  import Canada, only: [can?: 2]

  alias Ret.{
    AppConfig,
    Hub,
    HubInvite,
    Account,
    AccountFavorite,
    Identity,
    Repo,
    RoomObject,
    OwnedFile,
    Scene,
    Storage,
    SessionStat,
    Statix,
    WebPushSubscription
  }

  alias RetWeb.{Presence, EntityView}
  alias RetWeb.Api.V1.{HubView}

  intercept [
    "hub_refresh",
    "mute",
    "add_owner",
    "remove_owner",
    "message",
    "block",
    "unblock",
    # See internal_naf_event_for/2
    "maybe-naf",
    "maybe-nafr"
  ]

  def join("hub:" <> hub_sid, %{"profile" => profile, "context" => context} = params, socket) do
    hub =
      Hub
      |> Repo.get_by(hub_sid: hub_sid)
      |> Repo.preload(Hub.hub_preloads())

    socket
    |> assign(:profile, profile)
    |> assign(:context, context)
    |> assign(:block_naf, false)
    |> assign(:blocked_session_ids, %{})
    |> assign(:blocked_by_session_ids, %{})
    |> assign(:has_blocks, false)
    |> assign(:has_embeds, false)
    |> perform_join(
      hub,
      context,
      params
      |> Map.take([
        "push_subscription_endpoint",
        "auth_token",
        "perms_token",
        "bot_access_key",
        "hub_invite_id"
      ])
    )
  end

  defp perform_join(_socket, nil, _context, _params) do
    Statix.increment("ret.channels.hub.joins.not_found")
    {:error, %{message: "No such Hub", reason: "not_found"}}
  end

  defp perform_join(socket, hub, context, params) do
    account =
      case Ret.Guardian.resource_from_token(params["auth_token"]) do
        {:ok, %Account{} = account, _claims} -> account
        _ -> nil
      end

    hub_requires_oauth = hub.hub_bindings |> Enum.empty?() |> Kernel.not()

    bot_access_key = Application.get_env(:ret, :bot_access_key)
    has_valid_bot_access_key = !!(bot_access_key && params["bot_access_key"] == bot_access_key)

    account_has_provider_for_hub =
      account |> Ret.Account.matching_oauth_providers(hub) |> Enum.empty?() |> Kernel.not()

    account_can_join = account |> can?(join_hub(hub))
    account_can_update = account |> can?(update_hub(hub))

    perms_token = params["perms_token"]

    has_perms_token = perms_token != nil

    decoded_perms = perms_token |> Ret.PermsToken.decode_and_verify()

    perms_token_can_join =
      case decoded_perms do
        {:ok, %{"join_hub" => true}} -> true
        _ -> false
      end

    {oauth_account_id, oauth_source} =
      case decoded_perms do
        {:ok, %{"oauth_account_id" => oauth_account_id, "oauth_source" => oauth_source}} ->
          {oauth_account_id, oauth_source |> String.to_atom()}

        _ ->
          {nil, nil}
      end

    has_active_invite = Ret.HubInvite.active?(hub, params["hub_invite_id"])

    params =
      params
      |> Map.merge(%{
        has_active_invite: has_active_invite,
        hub_requires_oauth: hub_requires_oauth,
        has_valid_bot_access_key: has_valid_bot_access_key,
        account_has_provider_for_hub: account_has_provider_for_hub,
        account_can_join: account_can_join,
        account_can_update: account_can_update,
        has_perms_token: has_perms_token,
        oauth_account_id: oauth_account_id,
        oauth_source: oauth_source,
        perms_token_can_join: perms_token_can_join
      })

    hub |> join_with_hub(account, socket, context, params)
  end

  # Optimization: "raw" NAF event, with the underlying NAF payload as a string.
  # By going through this event, the server can avoid parsing the NAF messages.
  def handle_in("nafr" = event, %{"naf" => naf_payload} = payload, socket) do
    # We expect the client to have stripped the "isFirstSync" keys from the message
    # for this optimization.
    if !String.contains?(naf_payload, "isFirstSync") do
      broadcast_from!(
        socket,
        event |> internal_naf_event_for(socket),
        payload |> payload_with_from(socket)
      )

      {:noreply, socket}
    else
      # Full syncs must be properly authorized
      handle_in("naf", naf_payload |> Jason.decode!(), socket)
    end
  end

  # Captures all inbound NAF messages that result in spawned objects.
  def handle_in(
        "naf" = event,
        %{"data" => %{"isFirstSync" => true, "persistent" => false, "template" => template}} =
          payload,
        socket
      ) do
    data = payload["data"]

    if template |> spawn_permitted?(socket) do
      data =
        data
        |> Map.put("creator", socket.assigns.session_id)
        |> Map.put("owner", socket.assigns.session_id)

      payload = payload |> Map.put("data", data)

      broadcast_from!(
        socket,
        event |> internal_naf_event_for(socket),
        payload |> payload_with_from(socket)
      )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Captures all inbound NAF Update Multi messages
  def handle_in(
        "naf" = event,
        %{"dataType" => "um", "data" => %{"d" => updates}} = payload,
        socket
      ) do
    if updates |> Enum.any?(& &1["isFirstSync"]) do
      # Do not broadcast "um" messages that contain isFirstSyncs. NAF should never send these, so we'd only see them
      # from a malicious client.
      {:noreply, socket}
    else
      broadcast_from!(
        socket,
        event |> internal_naf_event_for(socket),
        payload |> payload_with_from(socket)
      )

      {:noreply, socket}
    end
  end

  # Fallthrough for all other NAF dataTypes
  def handle_in("naf" = event, payload, socket) do
    broadcast_from!(
      socket,
      event |> internal_naf_event_for(socket),
      payload |> payload_with_from(socket)
    )

    {:noreply, socket}
  end

  def handle_in("events:entering", _payload, socket) do
    context = socket.assigns.context || %{}

    socket =
      socket
      |> assign(:context, context |> Map.put("entering", true))
      |> broadcast_presence_update

    {:noreply, socket}
  end

  def handle_in("events:entering_cancelled", _payload, socket) do
    context = socket.assigns.context || %{}

    socket =
      socket |> assign(:context, context |> Map.delete("entering")) |> broadcast_presence_update

    {:noreply, socket}
  end

  def handle_in("events:entered", %{"initialOccupantCount" => occupant_count} = payload, socket) do
    socket =
      socket
      |> handle_max_occupant_update(occupant_count)
      |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:entered", payload, socket) do
    socket = socket |> handle_entered_event(payload)

    Statix.increment("ret.channels.hub.event_entered", 1)

    {:noreply, socket}
  end

  def handle_in("events:object_spawned", %{"object_type" => object_type}, socket) do
    socket = socket |> handle_object_spawned(object_type)

    Statix.increment("ret.channels.hub.objects_spawned", 1)

    {:noreply, socket}
  end

  def handle_in("events:request_support", _payload, socket) do
    hub = socket |> hub_for_socket
    Task.start_link(fn -> hub |> Ret.Support.request_support_for_hub() end)

    {:noreply, socket}
  end

  def handle_in("events:profile_updated", %{"profile" => profile}, socket) do
    socket = socket |> assign(:profile, profile) |> broadcast_presence_update
    {:noreply, socket}
  end

  def handle_in("events:begin_recording", _payload, socket),
    do: socket |> set_presence_flag(:recording, true)

  def handle_in("events:end_recording", _payload, socket),
    do: socket |> set_presence_flag(:recording, false)

  def handle_in("events:raise_hand", _payload, socket),
    do: socket |> set_presence_flag(:hand_raised, true)

  def handle_in("events:lower_hand", _payload, socket),
    do: socket |> set_presence_flag(:hand_raised, false)

  def handle_in("events:begin_streaming", _payload, socket),
    do: socket |> set_presence_flag(:streaming, true)

  def handle_in("events:end_streaming", _payload, socket),
    do: socket |> set_presence_flag(:streaming, false)

  def handle_in("events:begin_typing", _payload, socket),
    do: socket |> set_presence_flag(:typing, true)

  def handle_in("events:end_typing", _payload, socket),
    do: socket |> set_presence_flag(:typing, false)

  def handle_in("message" = event, %{"type" => type} = payload, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    authorized =
      cond do
        type in ["photo", "video"] -> account |> can?(spawn_camera(hub))
        type === "chat" -> account |> can?(text_chat(hub))
        type === "permission" -> account |> can?(update_hub(hub))
        true -> true
      end

    if authorized do
      broadcast!(
        socket,
        event,
        payload
        |> Map.delete("session_id")
        |> Map.put(:session_id, socket.assigns.session_id)
        |> payload_with_from(socket)
      )
    end

    {:noreply, socket}
  end

  def handle_in("mute" = event, payload, socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(mute_users(hub)) do
      broadcast_from!(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_in("subscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.subscribe_to_hub(subscription)

    {:noreply, socket}
  end

  def handle_in("favorite", _params, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    socket |> hub_for_socket |> AccountFavorite.ensure_favorited(account)
    {:noreply, socket}
  end

  def handle_in("unfavorite", _params, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    socket |> hub_for_socket |> AccountFavorite.ensure_not_favorited(account)
    {:noreply, socket}
  end

  def handle_in("unsubscribe", %{"subscription" => subscription}, socket) do
    socket
    |> hub_for_socket
    |> WebPushSubscription.unsubscribe_from_hub(subscription)

    has_remaining_subscriptions =
      WebPushSubscription.endpoint_has_subscriptions?(subscription["endpoint"])

    {:reply, {:ok, %{has_remaining_subscriptions: has_remaining_subscriptions}}, socket}
  end

  def handle_in("sign_in", %{"token" => token} = payload, socket) do
    creator_assignment_token = payload["creator_assignment_token"]

    case Ret.Guardian.resource_from_token(token) do
      {:ok, %Account{} = account, _claims} ->
        socket = Guardian.Phoenix.Socket.put_current_resource(socket, account)

        hub = socket |> hub_for_socket |> Repo.preload(Hub.hub_preloads())

        hub =
          if creator_assignment_token do
            hub
            |> Hub.changeset_for_creator_assignment(account, creator_assignment_token)
            |> Repo.update!()
          else
            hub
          end

        perms_token = get_perms_token(hub, account)
        broadcast_presence_update(socket)

        {:reply, {:ok, %{perms_token: perms_token}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{message: "Sign in failed", reason: reason}}, socket}
    end
  end

  def handle_in("sign_out", _payload, socket) do
    socket = Guardian.Phoenix.Socket.put_current_resource(socket, nil)
    broadcast_presence_update(socket)

    # Disconnect if signing out and account is required
    if AppConfig.get_cached_config_value("features|require_account_for_join") do
      Process.send_after(self(), :close_channel, 5000)
    end

    {:reply, {:ok, %{}}, socket}
  end

  def handle_in(
        "pin",
        %{
          "id" => object_id,
          "gltf_node" => gltf_node,
          "file_id" => file_id,
          "file_access_token" => file_access_token,
          "promotion_token" => promotion_token
        },
        socket
      ) do
    with_account(socket, fn account ->
      hub = socket |> hub_for_socket

      if account |> can?(pin_objects(hub)) do
        perform_pin!(object_id, gltf_node, account, socket)
        Storage.promote(file_id, file_access_token, promotion_token, account)
        OwnedFile.set_active(file_id, account.account_id)
      end
    end)
  end

  def handle_in("pin", %{"id" => object_id, "gltf_node" => gltf_node}, socket) do
    with_account(socket, fn account ->
      hub = socket |> hub_for_socket

      if account |> can?(pin_objects(hub)) do
        perform_pin!(object_id, gltf_node, account, socket)
      end
    end)
  end

  def handle_in("unpin", %{"id" => object_id, "file_id" => file_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        if account |> can?(pin_objects(hub)) do
          RoomObject.perform_unpin(hub, object_id)
          OwnedFile.set_inactive(file_id, account.account_id)
        end

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("unpin", %{"id" => object_id}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        if account |> can?(pin_objects(hub)) do
          RoomObject.perform_unpin(hub, object_id)
        end

      _ ->
        nil
    end

    {:noreply, socket}
  end

  def handle_in("list_entities", _, socket) do
    hub = socket |> hub_for_socket
    entities = Ret.list_entities(hub.hub_id)
    {:reply, {:ok, EntityView.render("index.json", %{entities: entities})}, socket}
  end

  def handle_in("save_entity_state", params, socket) do
    params = parse(params)

    with {:ok, hub, account} <- authorize(socket, :write_entity_state),
         {:ok, %{entity: entity}} <- Ret.create_entity(hub, params),
         :ok <- maybe_promote_file(params, account, socket) do
      entity = Repo.preload(entity, [:sub_entities])

      broadcast!(
        socket,
        "entity_state_saved",
        EntityView.render("show.json", %{entity: entity})
      )

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        reply_error(socket, reason)
    end
  end

  def handle_in("update_entity_state", %{"update_message" => update_message} = params, socket) do
    params = parse(params)

    with {:ok, hub, _account} <- authorize(socket, :write_entity_state),
         {:ok, _} <- Ret.insert_or_update_sub_entity(hub, params) do
      broadcast!(socket, "entity_state_updated", update_message)
      {:reply, :ok, socket}
    else
      {:error, reason} ->
        reply_error(socket, reason)
    end
  end

  def handle_in("delete_entity_state", %{"nid" => nid} = payload, socket) do
    with {:ok, hub, account} <- authorize(socket, :write_entity_state),
         {:ok, _} <- Ret.delete_entity(hub.hub_id, nid),
         {:ok, _} <- maybe_set_owned_file_inactive(payload, account) do
      RoomObject.perform_unpin(hub, nid)

      broadcast!(socket, "entity_state_deleted", %{
        "nid" => nid,
        "creator" => socket.assigns.session_id
      })

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        reply_error(socket, reason)
    end
  end

  def handle_in("get_host", _args, socket) do
    hub = socket |> hub_for_socket |> Hub.ensure_host()

    {:reply, {:ok, %{host: hub.host, port: Hub.janus_port(), turn: Hub.generate_turn_info()}},
     socket}
  end

  def handle_in("update_hub", payload, socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      name_changed = hub.name != payload["name"]
      description_changed = hub.description != payload["description"]

      member_permissions_changed =
        hub.member_permissions != payload |> Hub.member_permissions_from_attrs()

      room_size_changed = hub.room_size != payload["room_size"]
      can_change_promotion = account |> can?(update_hub_promotion(hub))

      promotion_changed =
        can_change_promotion and hub.allow_promotion != payload["allow_promotion"]

      # Older clients may not send an entry_mode in the payload.
      entry_mode_changed =
        payload["entry_mode"] !== nil and hub.entry_mode != payload["entry_mode"]

      stale_fields = []
      stale_fields = if name_changed, do: ["name" | stale_fields], else: stale_fields

      stale_fields =
        if description_changed, do: ["description" | stale_fields], else: stale_fields

      stale_fields =
        if member_permissions_changed,
          do: ["member_permissions" | stale_fields],
          else: stale_fields

      stale_fields = if room_size_changed, do: ["room_size" | stale_fields], else: stale_fields

      stale_fields =
        if promotion_changed, do: ["allow_promotion" | stale_fields], else: stale_fields

      stale_fields = if entry_mode_changed, do: ["entry_mode" | stale_fields], else: stale_fields

      hub
      |> Hub.add_attrs_to_changeset(payload)
      |> Hub.add_member_permissions_to_changeset(payload)
      |> Hub.maybe_add_promotion_to_changeset(account, hub, payload)
      |> Hub.maybe_add_entry_mode_to_changeset(payload)
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads())
      |> broadcast_hub_refresh!(socket, stale_fields)
    end

    {:noreply, socket}
  end

  def handle_in("fetch_invite", _payload, socket) do
    hub = hub_for_socket(socket)
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      hub_invite = hub |> HubInvite.find_or_create_invite_for_hub()
      {:reply, {:ok, %{hub_invite_id: hub_invite && hub_invite.hub_invite_sid}}, socket}
    else
      {:reply, {:ok, %{}}, socket}
    end
  end

  def handle_in("revoke_invite", payload, socket) do
    hub = hub_for_socket(socket)
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) and HubInvite.active?(hub, payload["hub_invite_id"]) do
      HubInvite.revoke_invite(hub, payload["hub_invite_id"])

      # Hubs can only have one invite for now, so we create a new one when the old one was revoked.
      hub_invite = hub |> HubInvite.find_or_create_invite_for_hub()
      {:reply, {:ok, %{hub_invite_id: hub_invite.hub_invite_sid}}, socket}
    else
      {:reply, {:ok, %{}}, socket}
    end
  end

  def handle_in("close_hub", _payload, socket) do
    socket |> handle_entry_mode_change(:deny)
  end

  def handle_in("update_scene", %{"url" => url}, socket) do
    hub = socket |> hub_for_socket |> Repo.preload([:scene, :scene_listing])
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(update_hub(hub)) do
      endpoint_host = RetWeb.Endpoint.host()

      case url |> URI.parse() do
        %URI{host: ^endpoint_host, path: "/scenes/" <> scene_path} ->
          scene_or_listing =
            scene_path |> String.split("/") |> Enum.at(0) |> Scene.scene_or_scene_listing_by_sid()

          hub |> Hub.changeset_for_new_scene(scene_or_listing)

        _ ->
          hub |> Hub.changeset_for_new_environment_url(url)
      end
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads(), force: true)
      |> broadcast_hub_refresh!(socket, ["scene"])
    end

    {:noreply, socket}
  end

  def handle_in(
        "refresh_perms_token",
        _args,
        %{assigns: %{oauth_account_id: oauth_account_id, oauth_source: oauth_source}} = socket
      )
      when oauth_account_id != nil do
    perms_token =
      socket
      |> hub_for_socket
      |> get_perms_token(%Ret.OAuthProvider{
        provider_account_id: oauth_account_id,
        source: oauth_source
      })

    {:reply, {:ok, %{perms_token: perms_token}}, socket}
  end

  def handle_in("refresh_perms_token", _args, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    perms_token = socket |> hub_for_socket |> get_perms_token(account)
    {:reply, {:ok, %{perms_token: perms_token}}, socket}
  end

  def handle_in("block" = event, %{"session_id" => session_id} = payload, socket) do
    socket =
      socket
      |> assign(
        :blocked_session_ids,
        socket.assigns.blocked_session_ids |> Map.put(session_id, true)
      )
      |> assign_has_blocks

    broadcast_from!(socket, event, payload |> payload_with_from(socket))
    {:noreply, socket}
  end

  def handle_in("unblock" = event, %{"session_id" => session_id} = payload, socket) do
    socket =
      socket
      |> assign(
        :blocked_session_ids,
        socket.assigns.blocked_session_ids |> Map.delete(session_id)
      )
      |> assign_has_blocks

    broadcast_from!(socket, event, payload |> payload_with_from(socket))
    {:noreply, socket}
  end

  def handle_in("kick", %{"session_id" => session_id}, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    if account |> can?(kick_users(hub)) do
      RetWeb.Endpoint.broadcast("session:#{session_id}", "disconnect", %{})
    end

    {:noreply, socket}
  end

  # NOTE: block_naf will only work if the hub is embedded. We *only* enable packet filtering
  # (and therefore, only respect block_naf) when a hub is embedded (or if there are blocks on the socket.)
  def handle_in("block_naf", _payload, socket), do: {:noreply, socket |> assign(:block_naf, true)}

  def handle_in("unblock_naf", _payload, socket),
    do: {:noreply, socket |> assign(:block_naf, false)}

  def handle_in(event, %{"session_id" => _session_id} = payload, socket)
      when event in ["add_owner", "remove_owner"] do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    if account |> can?(update_roles(hub)) do
      broadcast_from!(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_in("oauth", %{"type" => "twitter"}, socket) do
    hub = socket |> hub_for_socket

    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        case Ret.TwitterClient.get_oauth_url(hub.hub_sid, account.account_id) do
          {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
          url -> {:reply, {:ok, %{oauth_url: url}}, socket}
        end

      _ ->
        {:reply, :error, socket}
    end
  end

  def handle_in(_message, _payload, socket) do
    {:noreply, socket}
  end

  # If the maybe- variant of the naf/nafr messages are seen, we are performing packet filtering due to blocks
  # or iframe embeds opting out of NAF traffic. Handle them appropriately. (This is expensive, and should be rare!)
  def handle_out(event, payload, socket) when event in ["maybe-nafr"] do
    %{
      block_naf: block_naf,
      blocked_session_ids: blocked_session_ids,
      blocked_by_session_ids: blocked_by_session_ids
    } = socket.assigns

    socket
    |> maybe_push_naf("nafr", payload, block_naf, blocked_session_ids, blocked_by_session_ids)
  end

  def handle_out(event, payload, socket) when event in ["maybe-naf"] do
    %{
      block_naf: block_naf,
      blocked_session_ids: blocked_session_ids,
      blocked_by_session_ids: blocked_by_session_ids
    } = socket.assigns

    socket
    |> maybe_push_naf("naf", payload, block_naf, blocked_session_ids, blocked_by_session_ids)
  end

  def handle_out("mute" = event, %{"session_id" => session_id} = payload, socket) do
    if socket.assigns.session_id == session_id do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_out("hub_refresh" = event, %{stale_fields: stale_fields} = payload, socket) do
    push(socket, event, payload)

    if stale_fields |> Enum.member?("member_permissions") do
      # If hub member permissions change, everyone should flush their new permissions into presence so that other
      # clients can correctly authorized their actions.
      broadcast_presence_update(socket)
    end

    {:noreply, socket}
  end

  def handle_out(
        "block",
        %{"session_id" => session_id, :from_session_id => from_session_id},
        socket
      ) do
    socket =
      if socket.assigns.session_id === session_id do
        socket
        |> assign(
          :blocked_by_session_ids,
          socket.assigns.blocked_by_session_ids |> Map.put(from_session_id, true)
        )
        |> assign_has_blocks
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_out(
        "unblock",
        %{"session_id" => session_id, :from_session_id => from_session_id},
        socket
      ) do
    socket =
      if socket.assigns.session_id === session_id do
        socket
        |> assign(
          :blocked_by_session_ids,
          socket.assigns.blocked_by_session_ids |> Map.delete(from_session_id)
        )
        |> assign_has_blocks
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_out(event, %{"session_id" => session_id}, socket)
      when event in ["add_owner", "remove_owner"] do
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account && socket.assigns.session_id == session_id do
      # Outgoing message has already had a permission check on the sender side, so perform the action
      action =
        if event == "add_owner" do
          &Hub.add_owner!/2
        else
          &Hub.remove_owner!/2
        end

      socket |> hub_for_socket |> action.(account)

      broadcast_presence_update(socket)
      push(socket, "permissions_updated", %{})
    end

    {:noreply, socket}
  end

  def handle_out("message" = event, %{from_session_id: from_session_id} = payload, socket) do
    blocked_session_ids = socket.assigns.blocked_session_ids
    blocked_by_session_ids = socket.assigns.blocked_by_session_ids

    if !Map.has_key?(blocked_session_ids, from_session_id) and
         !Map.has_key?(blocked_by_session_ids, from_session_id) do
      push(socket, event, payload |> payload_without_from)
    end

    {:noreply, socket}
  end

  def handle_out("host_changed" = event, payload, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  defp maybe_push_naf(
         socket,
         event,
         payload,
         false = _block_naf,
         blocked_session_ids,
         blocked_by_session_ids
       )
       when blocked_session_ids === %{} and blocked_by_session_ids === %{} do
    push(socket, event, payload)
    {:noreply, socket}
  end

  defp maybe_push_naf(
         socket,
         event,
         %{from_session_id: from_session_id} = payload,
         false = _block_naf,
         blocked_session_ids,
         blocked_by_session_ids
       ) do
    if !Map.has_key?(blocked_session_ids, from_session_id) and
         !Map.has_key?(blocked_by_session_ids, from_session_id) do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  # Sockets can block NAF as an optimization, eg iframe embeds do not need NAF messages until user clicks load
  defp maybe_push_naf(
         socket,
         _event,
         _payload,
         true = _block_naf,
         _blocked_session_ids,
         _blocked_by_session_ids
       ) do
    {:noreply, socket}
  end

  defp spawn_permitted?(template, socket) do
    account = Guardian.Phoenix.Socket.current_resource(socket)
    hub = socket |> hub_for_socket

    cond do
      template |> String.ends_with?("-avatar") -> true
      template |> String.ends_with?("-media") -> account |> can?(spawn_and_move_media(hub))
      template |> String.ends_with?("-camera") -> account |> can?(spawn_camera(hub))
      template |> String.ends_with?("-drawing") -> account |> can?(spawn_drawing(hub))
      template |> String.ends_with?("-pen") -> account |> can?(spawn_drawing(hub))
      template |> String.ends_with?("-emoji") -> account |> can?(spawn_emoji(hub))
      # We want to forbid messages if they fall through the above list of template suffixes
      true -> false
    end
  end

  defp handle_entry_mode_change(socket, entry_mode) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    if account |> can?(close_hub(hub)) do
      hub
      |> Hub.changeset_for_entry_mode(entry_mode)
      |> Repo.update!()
      |> Repo.preload(Hub.hub_preloads())
      |> broadcast_hub_refresh!(socket, ["entry_mode"])
    end

    {:noreply, socket}
  end

  defp with_account(socket, handler) do
    case Guardian.Phoenix.Socket.current_resource(socket) do
      %Account{} = account ->
        handler.(account)
        {:reply, {:ok, %{}}, socket}

      _ ->
        # client should have signed-in at this point,
        # so if we still don't have an account, it must have been an invalid token
        {:reply, {:error, %{reason: :invalid_token}}, socket}
    end
  end

  defp account_for_socket(socket) do
    case Guardian.Phoenix.Socket.current_resource(socket) do
      nil ->
        {:error, :not_logged_in}

      account ->
        {:ok, account}
    end
  end

  defp auth(hub, account, :write_entity_state) do
    if can?(account, pin_objects(hub)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorize(socket, :write_entity_state) do
    hub = hub_for_socket(socket)

    with {:ok, account} <- account_for_socket(socket),
         :ok <- auth(hub, account, :write_entity_state) do
      {:ok, hub, account}
    end
  end

  def handle_info({:begin_tracking, session_id, _hub_sid}, socket) do
    {:ok, _} = Presence.track(socket, session_id, socket |> presence_meta_for_socket)
    push(socket, "presence_state", socket |> Presence.list())

    {:noreply, socket}
  end

  def handle_info(:close_channel, socket) do
    GenServer.cast(self(), :close)
    {:noreply, socket}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp perform_pin!(object_id, gltf_node, account, socket) do
    hub = socket |> hub_for_socket
    RoomObject.perform_pin!(hub, account, %{object_id: object_id, gltf_node: gltf_node})
    broadcast_pinned_media(socket, object_id, gltf_node)
  end

  def terminate(_reason, socket) do
    # enable_terminate_actions is set to false during tests. Since the GenServer is forcefully
    # terminated when a test ends, we want to avoid running into an error that would happen if we
    # invoked a DB mutation during termination.
    if Application.get_env(:ret, __MODULE__)[:enable_terminate_actions] !== false do
      socket
      |> SessionStat.stat_query_for_socket()
      |> Repo.update_all(set: [ended_at: NaiveDateTime.utc_now()])
    end

    :ok
  end

  defp set_presence_flag(socket, flag, value) do
    socket = socket |> assign(flag, value) |> broadcast_presence_update
    {:noreply, socket}
  end

  defp broadcast_presence_update(socket) do
    Presence.update(socket, socket.assigns.session_id, socket |> presence_meta_for_socket)
    socket
  end

  defp broadcast_pinned_media(socket, object_id, gltf_node) do
    broadcast!(socket, "pin", %{
      object_id: object_id,
      gltf_node: gltf_node,
      pinned_by: socket.assigns.session_id
    })
  end

  # Broadcasts the full hub info as well as an (optional) list of specific fields which
  # clients should consider stale and need to be updated in client state from the new
  # hub info
  #
  # Note this doesn't necessarily mean the fields have changed.
  #
  # For example, if the scene needs to be refreshed, this message indicates that by including
  # "scene" in the list of stale fields.
  defp broadcast_hub_refresh!(hub, socket, stale_fields) do
    account = Guardian.Phoenix.Socket.current_resource(socket)

    response =
      HubView.render("show.json", %{hub: hub, embeddable: account |> can?(embed_hub(hub))})
      |> Map.put(:session_id, socket.assigns.session_id)
      |> Map.put(:stale_fields, stale_fields)

    broadcast!(socket, "hub_refresh", response)
  end

  defp presence_meta_for_socket(socket) do
    hub = socket |> hub_for_socket
    account = Guardian.Phoenix.Socket.current_resource(socket)

    socket.assigns
    |> maybe_override_identifiers(account)
    |> Map.put(:roles, hub |> Hub.roles_for_account(account))
    |> Map.put(:permissions, hub |> Hub.perms_for_account(account))
    |> Map.take([
      :presence,
      :profile,
      :context,
      :roles,
      :permissions,
      :streaming,
      :recording,
      :hand_raised,
      :typing
    ])
  end

  # Hubs Bot can set their own display name.
  defp maybe_override_identifiers(
         %{
           hub_requires_oauth: true,
           has_valid_bot_access_key: true
         } = assigns,
         _account
       ),
       do: assigns

  # Do a direct display name lookup for OAuth users without a verified email (and thus, no Hubs account).
  defp maybe_override_identifiers(
         %{
           hub_requires_oauth: true,
           hub_sid: hub_sid,
           oauth_source: oauth_source,
           oauth_account_id: oauth_account_id
         } = assigns,
         _account
       )
       when not is_nil(oauth_source) and not is_nil(oauth_account_id) do
    hub = Hub |> Repo.get_by(hub_sid: hub_sid) |> Repo.preload(:hub_bindings)

    # Assume hubs only have a single hub binding for now.
    hub_binding = hub.hub_bindings |> Enum.at(0)

    oauth_provider = %Ret.OAuthProvider{
      source: oauth_source,
      provider_account_id: oauth_account_id
    }

    assigns |> override_display_name_via_binding(oauth_provider, hub_binding)
  end

  # If there isn't an oauth account id on the socket, we expect the user to have an account
  defp maybe_override_identifiers(
         %{
           hub_requires_oauth: true,
           hub_sid: hub_sid,
           oauth_account_id: oauth_account_id
         } = assigns,
         account
       )
       when is_nil(oauth_account_id) do
    hub = Hub |> Repo.get_by(hub_sid: hub_sid) |> Repo.preload(:hub_bindings)

    # Assume hubs only have a single hub binding for now.
    hub_binding = hub.hub_bindings |> Enum.at(0)

    # There's no way tell which oauth_provider a user would like to identify with. We're just going to pick
    # the first one for now.
    oauth_provider =
      account.oauth_providers
      |> Enum.filter(fn provider -> hub_binding.type == provider.source end)
      |> Enum.at(0)

    assigns |> override_display_name_via_binding(oauth_provider, hub_binding)
  end

  # For unbound hubs, set the identity name for the account.
  defp maybe_override_identifiers(
         %{
           hub_requires_oauth: false
         } = assigns,
         %Account{identity: %Identity{name: name}}
       ),
       do: put_in(assigns.profile["identityName"], name)

  defp maybe_override_identifiers(
         %{
           hub_requires_oauth: false
         } = assigns,
         _account
       ),
       do: assigns

  defp override_display_name_via_binding(assigns, oauth_provider, hub_binding) do
    display_name = oauth_provider |> Ret.HubBinding.fetch_display_name(hub_binding)
    community_identifier = oauth_provider |> Ret.HubBinding.fetch_community_identifier()

    overriden =
      assigns.profile
      |> Map.merge(%{
        "displayName" => display_name,
        "identityName" => community_identifier,
        # Deprecated
        "communityIdentifier" => community_identifier
      })

    assigns |> Map.put(:profile, overriden)
  end

  defp join_with_hub(%Hub{entry_mode: :deny}, _account, _socket, _context, _params) do
    {:error, %{message: "Hub no longer accessible", reason: "closed"}}
  end

  defp join_with_hub(
         %Hub{},
         %Account{},
         _socket,
         _context,
         %{
           hub_requires_oauth: false,
           account_can_join: false
         }
       ),
       do: deny_join()

  defp join_with_hub(
         %Hub{entry_mode: :invite},
         _account,
         _socket,
         _context,
         %{
           has_active_invite: false,
           account_can_update: false
         }
       ),
       do: deny_join()

  defp join_with_hub(
         %Hub{},
         %Account{},
         _socket,
         _context,
         %{
           hub_requires_oauth: true,
           account_has_provider_for_hub: true,
           account_can_join: false
         }
       ),
       do: deny_join()

  defp join_with_hub(
         %Hub{},
         nil = _account,
         _socket,
         _context,
         %{
           hub_requires_oauth: true,
           has_valid_bot_access_key: false,
           has_perms_token: true,
           perms_token_can_join: false
         }
       ),
       do: deny_join()

  defp join_with_hub(
         %Hub{} = hub,
         %Account{},
         _socket,
         _context,
         %{
           hub_requires_oauth: true,
           account_has_provider_for_hub: false
         }
       ),
       do: require_oauth(hub)

  defp join_with_hub(
         %Hub{} = hub,
         nil = _account,
         _socket,
         _context,
         %{
           hub_requires_oauth: true,
           has_valid_bot_access_key: false,
           has_perms_token: false
         }
       ),
       do: require_oauth(hub)

  # Join denied based upon account requirement
  defp join_with_hub(
         %Hub{},
         nil = _account,
         _socket,
         _context,
         %{
           hub_requires_oauth: false,
           has_valid_bot_access_key: false,
           has_perms_token: false,
           account_can_join: false
         }
       ),
       do: deny_join()

  defp join_with_hub(%Hub{} = hub, account, socket, context, params) do
    hub = hub |> Hub.ensure_host()

    hub =
      if context["embed"] && !hub.embedded do
        hub
        |> Hub.changeset_for_seen_embedded_hub()
        |> Repo.update!()
      else
        hub
      end

    # Each channel connection needs to be aware if there are, or ever have been,
    # embeddings of this hub (see internal_naf_event_for/2)
    socket = socket |> assign(:has_embeds, hub.embedded)

    push_subscription_endpoint = params["push_subscription_endpoint"]

    is_push_subscribed =
      push_subscription_endpoint &&
        hub.web_push_subscriptions |> Enum.any?(&(&1.endpoint == push_subscription_endpoint))

    is_favorited = AccountFavorite.timestamp_join_if_favorited(hub, account)

    socket = Guardian.Phoenix.Socket.put_current_resource(socket, account)

    with socket <-
           socket
           |> assign(:hub_sid, hub.hub_sid)
           |> assign(:hub_requires_oauth, params[:hub_requires_oauth])
           |> assign(:presence, :lobby)
           |> assign(:oauth_account_id, params[:oauth_account_id])
           |> assign(:oauth_source, params[:oauth_source])
           |> assign(:has_valid_bot_access_key, params[:has_valid_bot_access_key]),
         response <-
           HubView.render("show.json", %{hub: hub, embeddable: account |> can?(embed_hub(hub))}) do
      perms_token = params["perms_token"] || get_perms_token(hub, account)

      response =
        response
        |> Map.put(:session_id, socket.assigns.session_id)
        |> Map.put(
          :session_token,
          socket.assigns.session_id |> Ret.SessionToken.token_for_session()
        )
        |> Map.put(:subscriptions, %{web_push: is_push_subscribed, favorites: is_favorited})
        |> Map.put(:perms_token, perms_token)
        |> Map.put(:hub_requires_oauth, params[:hub_requires_oauth])

      existing_stat_count =
        socket
        |> SessionStat.stat_query_for_socket()
        |> Repo.all()
        |> length

      unless existing_stat_count > 0 do
        with session_id <- socket.assigns.session_id,
             started_at <- socket.assigns.started_at,
             stat_attrs <- %{session_id: session_id, started_at: started_at},
             changeset <- %SessionStat{} |> SessionStat.changeset(stat_attrs) do
          Repo.insert(changeset)
        end
      end

      send(self(), {:begin_tracking, socket.assigns.session_id, hub.hub_sid})

      # Send join push notification if this is the first joiner
      if Presence.list(socket.topic) |> Enum.count() == 0 do
        Task.start_link(fn ->
          hub |> Hub.send_push_messages_for_join(push_subscription_endpoint)
        end)
      end

      Statix.increment("ret.channels.hub.joins.ok")

      {:ok, response, socket}
    end
  end

  defp require_oauth(hub) do
    oauth_info = hub.hub_bindings |> get_oauth_info(hub.hub_sid)
    {:error, %{message: "OAuth required", reason: "oauth_required", oauth_info: oauth_info}}
  end

  defp deny_join do
    {:error, %{message: "Join denied", reason: "join_denied"}}
  end

  defp get_oauth_info(hub_bindings, hub_sid) do
    hub_bindings
    |> Enum.map(
      &case &1 do
        %{type: :discord} -> %{type: :discord, url: Ret.DiscordClient.get_oauth_url(hub_sid)}
        %{type: :slack} -> %{type: :slack, url: Ret.SlackClient.get_oauth_url(hub_sid)}
      end
    )
  end

  defp get_perms_token(
         hub,
         %Ret.OAuthProvider{provider_account_id: provider_account_id, source: source} = account
       ) do
    hub
    |> Hub.perms_for_account(account)
    |> Map.put(:oauth_account_id, provider_account_id)
    |> Map.put(:oauth_source, source)
    |> Map.put(:hub_id, hub.hub_sid)
    |> Ret.PermsToken.token_for_perms()
  end

  defp get_perms_token(hub, account) do
    account_id = if account, do: account.account_id, else: nil

    hub
    |> Hub.perms_for_account(account)
    |> Account.add_global_perms_for_account(account)
    |> Map.put(:account_id, account_id |> to_string)
    |> Map.put(:hub_id, hub.hub_sid)
    |> Ret.PermsToken.token_for_perms()
  end

  defp handle_entered_event(socket, payload) do
    stat_attributes = [
      entered_event_payload: payload,
      entered_event_received_at: NaiveDateTime.utc_now()
    ]

    # Flip context to have HMD if entered with display type
    socket =
      with %{"entryDisplayType" => display} when is_binary(display) and display != "Screen" <-
             payload,
           %{context: context} when is_map(context) <- socket.assigns do
        socket |> assign(:context, context |> Map.put("hmd", true))
      else
        _ -> socket
      end

    socket
    |> SessionStat.stat_query_for_socket()
    |> Repo.update_all(set: stat_attributes)

    context = socket.assigns.context || %{}

    socket
    |> assign(:presence, :room)
    |> assign(:context, context |> Map.delete("entering"))
    |> broadcast_presence_update
  end

  defp handle_max_occupant_update(socket, occupant_count) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_seen_occupant_count(occupant_count)
    |> Repo.update!()

    socket
  end

  defp handle_object_spawned(socket, object_type) do
    socket
    |> hub_for_socket
    |> Hub.changeset_for_new_spawned_object_type(object_type)
    |> Repo.update!()

    socket
  end

  defp hub_for_socket(socket) do
    Repo.get_by(Hub, hub_sid: socket.assigns.hub_sid)
    |> Repo.preload([:hub_bindings, :hub_role_memberships])
  end

  defp payload_with_from(payload, socket) do
    payload |> Map.put(:from_session_id, socket.assigns.session_id)
  end

  defp payload_without_from(payload) do
    payload |> Map.delete(:from_session_id)
  end

  defp assign_has_blocks(socket) do
    has_blocks =
      socket.assigns.blocked_session_ids |> Enum.any?() ||
        socket.assigns.blocked_by_session_ids |> Enum.any?()

    socket |> assign(:has_blocks, has_blocks)
  end

  # Normally, naf and nafr messages are sent as is. However, if this connection is blocking users,
  # has been blocked, or the hub itself has been seen in an iframe, we need to potentially filter
  # NAF messages. As such, we internally route messages via an intercepted handle_out for filtering.
  # This is done via the intercepted maybe-nafr and maybe-naf events.
  #
  # We avoid doing this in general because it's extremely expensive, since it re-encodes all outgoing messages.
  defp internal_naf_event_for("nafr", %Phoenix.Socket{
         assigns: %{has_blocks: false, has_embeds: false}
       }),
       do: "nafr"

  defp internal_naf_event_for("naf", %Phoenix.Socket{
         assigns: %{has_blocks: false, has_embeds: false}
       }),
       do: "naf"

  defp internal_naf_event_for("nafr", _socket), do: "maybe-nafr"
  defp internal_naf_event_for("naf", _socket), do: "maybe-naf"

  defp parse(%{"nid" => nid, "root_nid" => root_nid, "update_message" => update_message}) do
    %{nid: nid, root_nid: root_nid, update_message: Jason.encode!(update_message)}
  end

  defp parse(
         %{
           "nid" => nid,
           "create_message" => create_message,
           "updates" => updates
         } = params
       ) do
    %{
      nid: nid,
      create_message: Jason.encode!(create_message),
      updates: Enum.map(updates, &parse/1),
      promotion_token: Map.get(params, "promotion_token", nil),
      file_id: Map.get(params, "file_id", nil),
      file_access_token: Map.get(params, "file_access_token", nil)
    }
  end

  defp maybe_set_owned_file_inactive(%{"file_id" => file_id}, _account) do
    OwnedFile.set_inactive(file_id)
  end

  defp maybe_set_owned_file_inactive(_payload, _account) do
    {:ok, :no_file}
  end

  defp maybe_promote_file(%{file_id: nil} = _params, _account, _socket) do
    :ok
  end

  defp maybe_promote_file(params, account, _socket) do
    with {:ok, _owned_file} <-
           Storage.promote(
             params.file_id,
             params.file_access_token,
             params.promotion_token,
             account,
             false
           ) do
      OwnedFile.set_active(params.file_id, account.account_id)
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reply_error(socket, reason) do
    {:reply, {:error, %{reason: reason}}, socket}
  end
end
