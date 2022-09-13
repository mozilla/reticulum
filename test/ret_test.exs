defmodule RetTest do
  use Ret.DataCase
  import Ecto.Query, only: [from: 2]
  import Ret.TestHelpers, except: [create_avatar: 1, create_avatar_listing: 1]

  alias Ret.{
    Account,
    AccountFavorite,
    Api,
    Avatar,
    AvatarListing,
    Hub,
    HubBinding,
    HubInvite,
    HubRoleMembership,
    Identity,
    Login,
    OAuthProvider,
    OwnedFile,
    Repo,
    RoomObject,
    Storage,
    WebPushSubscription
  }

  describe "account deletion" do
    test "deletes account, login, identity, oauthproviders, and api_credentials" do
      {:ok, admin_account: admin_account} = create_admin_account("admin")
      test_account = create_account("test")

      Account.set_identity!(test_account, "test identity")

      Repo.insert(%OAuthProvider{
        source: :discord,
        account: test_account,
        provider_account_id: "discord-test-user"
      })

      Api.TokenUtils.gen_token_for_account(test_account)

      %Account{} = Ret.get_account_by_id(test_account.account_id)
      1 = count(Login, test_account)
      1 = count(Identity, test_account)
      1 = count(OAuthProvider, test_account)
      1 = count(Api.Credentials, test_account)

      assert :ok = Ret.delete_account(admin_account, test_account)

      assert nil === Ret.get_account_by_id(test_account.account_id)
      assert 0 === count(Login, test_account)
      assert 0 === count(Identity, test_account)
      assert 0 === count(OAuthProvider, test_account)
      assert 0 === count(Api.Credentials, test_account)
    end

    test "deletes hub and associated entities" do
      {:ok, admin_account: admin_account} = create_admin_account("admin")
      test_account = create_account("test")
      test_hub_member_account = create_account("test_member")

      {:ok, hub} =
        Repo.insert(%Hub{
          name: "test hub",
          slug: "fake test slug",
          created_by_account: test_account
        })

      Repo.insert(%HubBinding{
        hub: hub,
        type: :discord,
        community_id: "fake-community-id",
        channel_id: "fake-channel-id"
      })

      Repo.insert(%AccountFavorite{
        hub: hub,
        account: test_account
      })

      Repo.insert(%HubInvite{
        hub: hub,
        hub_invite_sid: "fake-invite-sid"
      })

      Repo.insert(%HubRoleMembership{
        hub: hub,
        account: test_hub_member_account
      })

      Repo.insert(%RoomObject{
        hub: hub,
        account: test_account,
        object_id: "fake object id",
        gltf_node: "fake gltf node"
      })

      Repo.insert(%WebPushSubscription{
        hub: hub,
        endpoint: "fake-endpoint",
        p256dh: "fake-key",
        auth: "fake-auth-key"
      })

      1 = count_hubs(test_account)
      1 = count(AccountFavorite, hub)
      1 = count(HubBinding, hub)
      1 = count(HubInvite, hub)
      1 = count(HubRoleMembership, hub)
      1 = count(RoomObject, hub)
      1 = count(WebPushSubscription, hub)

      assert :ok = Ret.delete_account(admin_account, test_account)

      assert 0 === count_hubs(test_account)
      assert 0 === count(AccountFavorite, hub)
      assert 0 === count(HubBinding, hub)
      assert 0 === count(HubInvite, hub)
      assert 0 === count(HubRoleMembership, hub)
      assert 0 === count(RoomObject, hub)
      assert 0 === count(WebPushSubscription, hub)
    end

    test "deletes entities associated with an account, even when they belong to a hub owned by another account" do
      {:ok, admin_account: admin_account} = create_admin_account("test_admin")
      hub_owner = create_account("test_owner")
      hub_user = create_account("test_user")

      {:ok, hub} =
        Repo.insert(%Hub{
          name: "test hub",
          slug: "fake test slug",
          created_by_account: hub_owner
        })

      Repo.insert(%AccountFavorite{
        hub: hub,
        account: hub_user
      })

      Repo.insert(%HubRoleMembership{
        hub: hub,
        account: hub_user
      })

      Repo.insert(%RoomObject{
        hub: hub,
        account: hub_user,
        object_id: "fake object id",
        gltf_node: "fake gltf node"
      })

      1 = count_hubs(hub_owner)
      1 = count(AccountFavorite, hub)
      1 = count(HubRoleMembership, hub)
      1 = count(RoomObject, hub)

      assert :ok = Ret.delete_account(admin_account, hub_user)

      assert 1 === count_hubs(hub_owner)
      assert 0 === count(AccountFavorite, hub)
      assert 0 === count(HubRoleMembership, hub)
      assert 0 === count(RoomObject, hub)
    end

    test "deletes account's avatars" do
      {:ok, admin_account: admin_account} = create_admin_account("admin")
      test_account = create_account("test")

      [_avatar, avatar_owned_files] = create_avatar(test_account)

      1 = count(Avatar, test_account)
      7 = count(OwnedFile, test_account)
      true = owned_files_exist?(avatar_owned_files)

      assert :ok = Ret.delete_account(admin_account, test_account)

      assert 0 === count(Avatar, test_account)
      assert 0 === count(OwnedFile, test_account)
      refute owned_files_exist?(avatar_owned_files)
    end

    test "listed avatars are reassigned to admin account" do
      {:ok, admin_account: admin_account} = create_admin_account("admin")
      target_account = create_account("target")

      [avatar, avatar_owned_files] = create_avatar(target_account)
      create_avatar_listing(avatar)

      1 = count(Avatar, target_account)
      7 = count(OwnedFile, target_account)

      0 = count(Avatar, admin_account)
      0 = count(OwnedFile, admin_account)
      1 = count(AvatarListing)

      assert :ok = Ret.delete_account(admin_account, target_account)

      assert 0 === count(Avatar, target_account)
      assert 0 === count(OwnedFile, target_account)

      assert 1 === count(Avatar, admin_account)
      assert 7 === count(OwnedFile, admin_account)
      assert 1 === count(AvatarListing)

      assert owned_files_exist?(avatar_owned_files)
    end

    test "parent avatars are reassigned to admin account" do
      {:ok, admin_account: admin_account} = create_admin_account("admin")
      target_account = create_account("target")
      other_account = create_account("other")

      [avatar, avatar_owned_files] = create_avatar(target_account)
      create_child_avatar(avatar, other_account)

      1 = count(Avatar, target_account)
      7 = count(OwnedFile, target_account)

      1 = count(Avatar, other_account)
      0 = count(OwnedFile, other_account)

      0 = count(Avatar, admin_account)
      0 = count(OwnedFile, admin_account)

      assert :ok = Ret.delete_account(admin_account, target_account)

      assert 0 === count(Avatar, target_account)
      assert 0 === count(OwnedFile, target_account)

      assert 1 === count(Avatar, other_account)
      assert 0 === count(OwnedFile, other_account)

      assert 1 === count(Avatar, admin_account)
      assert 7 === count(OwnedFile, admin_account)

      assert owned_files_exist?(avatar_owned_files)
    end
  end

  defp create_avatar(account) do
    avatar_owned_files = 1..7 |> Enum.map(fn _ -> generate_temp_owned_file(account) end)

    [
      gltf_owned_file,
      bin_owned_file,
      thumbnail_owned_file,
      base_map_owned_file,
      emissive_map_owned_file,
      normal_map_owned_file,
      orm_map_owned_file
    ] = avatar_owned_files

    {:ok, avatar} =
      Repo.insert(%Avatar{
        account_id: account.account_id,
        name: "fake avatar",
        slug: "fake-avatar-slug",
        avatar_sid: "fake-avatar-sid",
        gltf_owned_file: gltf_owned_file,
        bin_owned_file: bin_owned_file,
        thumbnail_owned_file: thumbnail_owned_file,
        base_map_owned_file: base_map_owned_file,
        emissive_map_owned_file: emissive_map_owned_file,
        normal_map_owned_file: normal_map_owned_file,
        orm_map_owned_file: orm_map_owned_file
      })

    [avatar, avatar_owned_files]
  end

  defp create_avatar_listing(%Avatar{} = avatar) do
    Repo.insert(%AvatarListing{
      avatar_id: avatar.avatar_id,
      name: "fake avatar listing",
      slug: "fake-avatar-listing-slug",
      avatar_listing_sid: "fake-avatar-listing-sid",
      gltf_owned_file: avatar.gltf_owned_file,
      bin_owned_file: avatar.bin_owned_file,
      thumbnail_owned_file: avatar.thumbnail_owned_file,
      base_map_owned_file: avatar.base_map_owned_file,
      emissive_map_owned_file: avatar.emissive_map_owned_file,
      normal_map_owned_file: avatar.normal_map_owned_file,
      orm_map_owned_file: avatar.orm_map_owned_file
    })
  end

  defp create_child_avatar(%Avatar{} = avatar, %Account{} = account) do
    Repo.insert(%Avatar{
      account_id: account.account_id,
      parent_avatar_id: avatar.avatar_id,
      name: "fake child avatar",
      slug: "fake-child-avatar-slug",
      avatar_sid: "fake-child-avatar-sid"
    })
  end

  defp owned_files_exist?(owned_files) when is_list(owned_files) do
    Enum.all?(owned_files, fn owned_file ->
      [_base_path, meta_file_path, blob_file_path] = Storage.paths_for_owned_file(owned_file)
      File.exists?(meta_file_path) and File.exists?(blob_file_path)
    end)
  end

  defp count_hubs(account) do
    Ret.Repo.aggregate(
      from(h in Hub, where: h.created_by_account_id == ^account.account_id),
      :count
    )
  end

  defp count(queryable, %Account{} = account) do
    Ret.Repo.aggregate(
      from(record in queryable, where: record.account_id == ^account.account_id),
      :count
    )
  end

  defp count(queryable, %Hub{} = hub) do
    Ret.Repo.aggregate(
      from(record in queryable, where: record.hub_id == ^hub.hub_id),
      :count
    )
  end

  defp count(queryable) do
    Ret.Repo.aggregate(queryable, :count)
  end
end
