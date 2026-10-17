if Code.ensure_loaded?(Ecto.Query) do
  defmodule Sake.Auth.Store.Ecto do
    @moduledoc """
    The Ecto store: `store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}` with
    the tables from `Sake.Auth.Migration`. Tested on Postgres.
    """
    @behaviour Sake.Auth.Store
    import Ecto.Query

    alias Sake.Auth.{Client, Code, Consent, DeviceGrant, PushedRequest, TokenRecord}
    alias Sake.Auth.Store.Ecto, as: S

    @impl true
    def init(opts), do: %{repo: Keyword.fetch!(opts, :repo), prefix: opts[:prefix]}

    @impl true
    def put_client(%{repo: repo} = s, %Client{} = c) do
      row = %S.Client{
        id: c.id,
        name: c.name,
        kind: to_string(c.kind),
        redirect_uris: c.redirect_uris,
        grant_types: c.grant_types,
        token_endpoint_auth_method: c.token_endpoint_auth_method,
        secret_hash: c.secret_hash,
        logo_uri: c.logo_uri,
        client_uri: c.client_uri,
        scopes: c.scopes,
        jwks: c.jwks,
        jwks_uri: c.jwks_uri,
        application_type: c.application_type,
        dpop_bound_access_tokens: c.dpop_bound_access_tokens,
        require_pushed_authorization_requests: c.require_pushed_authorization_requests,
        inserted_at: c.inserted_at
      }

      {:ok, _} =
        repo.insert(row,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: :id,
          prefix: s.prefix
        )

      :ok
    end

    @impl true
    def get_client(%{repo: repo} = s, id) do
      case repo.get(S.Client, id, prefix: s.prefix) do
        nil -> :error
        row -> {:ok, client(row)}
      end
    end

    @impl true
    def list_clients(%{repo: repo} = s),
      do: S.Client |> repo.all(prefix: s.prefix) |> Enum.map(&client/1)

    @impl true
    def delete_client(%{repo: repo} = s, id) do
      repo.delete_all(from(c in S.Client, where: c.id == ^id), prefix: s.prefix)
      :ok
    end

    defp client(r) do
      %Client{
        id: r.id,
        name: r.name,
        kind: String.to_existing_atom(r.kind),
        redirect_uris: r.redirect_uris,
        grant_types: r.grant_types,
        token_endpoint_auth_method: r.token_endpoint_auth_method,
        secret_hash: r.secret_hash,
        logo_uri: r.logo_uri,
        client_uri: r.client_uri,
        scopes: r.scopes,
        jwks: r.jwks,
        jwks_uri: r.jwks_uri,
        application_type: r.application_type,
        dpop_bound_access_tokens: r.dpop_bound_access_tokens,
        require_pushed_authorization_requests: r.require_pushed_authorization_requests,
        inserted_at: r.inserted_at
      }
    end

    @impl true
    def put_code(%{repo: repo} = s, %Code{} = c) do
      row = %S.Code{
        hash: c.hash,
        client_id: c.client_id,
        redirect_uri: c.redirect_uri,
        code_challenge: c.code_challenge,
        scopes: c.scopes,
        resource: c.resource,
        subject_id: c.subject_id,
        dpop_jkt: c.dpop_jkt,
        expires_at: DateTime.truncate(c.expires_at, :second)
      }

      {:ok, _} = repo.insert(row, prefix: s.prefix)
      :ok
    end

    # A consumed code is marked used rather than deleted: its row is the
    # fence that `put_code_tokens/3` and `revoke_family/2` meet on, until
    # it expires and `prune/3` deletes it.
    @impl true
    def consume_code(%{repo: repo} = s, hash) do
      query = from(c in S.Code, where: c.hash == ^hash and is_nil(c.used_at), select: c)

      case repo.update_all(query, [set: [used_at: now()]], prefix: s.prefix) do
        {1, [r]} ->
          {:ok,
           %Code{
             hash: r.hash,
             client_id: r.client_id,
             redirect_uri: r.redirect_uri,
             code_challenge: r.code_challenge,
             scopes: r.scopes,
             resource: r.resource,
             subject_id: r.subject_id,
             dpop_jkt: r.dpop_jkt,
             expires_at: r.expires_at
           }}

        _ ->
          :error
      end
    end

    # The code's row, locked: a concurrent `revoke_family/2` of its family
    # waits for this transaction, and its sweep then sees the tokens; one
    # that ran first left the row revoked, and nothing is inserted. A row
    # gone (the code expired and was pruned) counts as revoked.
    @impl true
    def put_code_tokens(%{repo: repo} = s, code_hash, tokens) do
      fence =
        from(c in S.Code,
          where: c.hash == ^code_hash and not is_nil(c.used_at) and is_nil(c.revoked_at),
          lock: "FOR UPDATE",
          select: c.hash
        )

      {:ok, result} =
        repo.transaction(fn ->
          case repo.one(fence, prefix: s.prefix) do
            nil -> :revoked
            _ -> Enum.each(tokens, &(:ok = put_token(s, &1)))
          end
        end)

      result
    end

    @impl true
    def put_pushed_request(%{repo: repo} = s, %PushedRequest{} = p) do
      row = %S.PushedRequest{
        hash: p.hash,
        client_id: p.client_id,
        redirect_uri: p.redirect_uri,
        state: p.state,
        code_challenge: p.code_challenge,
        scopes: p.scopes,
        resource: p.resource,
        extra: p.extra,
        expires_at: DateTime.truncate(p.expires_at, :second),
        inserted_at: DateTime.truncate(p.inserted_at || DateTime.utc_now(), :second)
      }

      {:ok, _} = repo.insert(row, prefix: s.prefix)
      :ok
    end

    # One statement, which deletes the row and returns it: of two
    # concurrent takes, the second finds nothing to delete.
    @impl true
    def consume_pushed_request(%{repo: repo} = s, hash) do
      query = from(p in S.PushedRequest, where: p.hash == ^hash, select: p)

      case repo.delete_all(query, prefix: s.prefix) do
        {1, [r]} ->
          {:ok,
           %PushedRequest{
             hash: r.hash,
             client_id: r.client_id,
             redirect_uri: r.redirect_uri,
             state: r.state,
             code_challenge: r.code_challenge,
             scopes: r.scopes,
             resource: r.resource,
             extra: r.extra,
             expires_at: r.expires_at,
             inserted_at: r.inserted_at
           }}

        _ ->
          :error
      end
    end

    @impl true
    def put_device_grant(%{repo: repo} = s, %DeviceGrant{} = g) do
      row = %S.DeviceGrant{
        hash: g.hash,
        user_code_hash: g.user_code_hash,
        client_id: g.client_id,
        scopes: g.scopes,
        resource: g.resource,
        status: to_string(g.status),
        subject_id: g.subject_id,
        interval: g.interval,
        expires_at: DateTime.truncate(g.expires_at, :second),
        last_polled_at: g.last_polled_at,
        inserted_at: DateTime.truncate(g.inserted_at || DateTime.utc_now(), :second)
      }

      {:ok, _} = repo.insert(row, prefix: s.prefix)
      :ok
    end

    @impl true
    def get_device_grant_by_user_code(%{repo: repo} = s, user_code_hash) do
      case repo.one(from(g in S.DeviceGrant, where: g.user_code_hash == ^user_code_hash),
             prefix: s.prefix
           ) do
        nil -> :error
        row -> {:ok, device_grant(row)}
      end
    end

    # One statement: of two concurrent decisions, the second finds the
    # row no longer pending.
    @impl true
    def decide_device_grant(%{repo: repo} = s, hash, decision) do
      set =
        case decision do
          {:approved, subject_id, scopes} ->
            [status: "approved", subject_id: subject_id, scopes: scopes]

          :denied ->
            [status: "denied"]
        end

      query = from(g in S.DeviceGrant, where: g.hash == ^hash and g.status == "pending")

      case repo.update_all(query, [set: set], prefix: s.prefix) do
        {1, _} -> :ok
        {0, _} -> :error
      end
    end

    # The grant's row, locked while the poll is answered and recorded: of
    # two concurrent polls of an approved grant, the second waits, and
    # finds it issued.
    @impl true
    def poll_device_grant(%{repo: repo} = s, hash, client_id, now) do
      query = from(g in S.DeviceGrant, where: g.hash == ^hash, lock: "FOR UPDATE")

      {:ok, answer} =
        repo.transaction(fn ->
          case repo.one(query, prefix: s.prefix) do
            nil -> :error
            row -> row |> device_grant() |> DeviceGrant.poll(client_id, now) |> polled(s)
          end
        end)

      answer
    end

    defp polled({answer, nil}, _s), do: answer

    defp polled({answer, grant}, %{repo: repo} = s) do
      repo.update_all(
        from(g in S.DeviceGrant, where: g.hash == ^grant.hash),
        [set: [status: to_string(grant.status), last_polled_at: grant.last_polled_at]],
        prefix: s.prefix
      )

      answer
    end

    # The grant's row, locked, as for `put_code_tokens/3`: a concurrent
    # `revoke_family/2` waits for this transaction, or left the row
    # revoked, and nothing is inserted. A row gone (pruned) counts as
    # revoked.
    @impl true
    def put_device_tokens(%{repo: repo} = s, hash, tokens) do
      fence =
        from(g in S.DeviceGrant,
          where: g.hash == ^hash and g.status == "issued" and is_nil(g.revoked_at),
          lock: "FOR UPDATE",
          select: g.hash
        )

      {:ok, result} =
        repo.transaction(fn ->
          case repo.one(fence, prefix: s.prefix) do
            nil -> :revoked
            _ -> Enum.each(tokens, &(:ok = put_token(s, &1)))
          end
        end)

      result
    end

    defp device_grant(r) do
      %DeviceGrant{
        hash: r.hash,
        user_code_hash: r.user_code_hash,
        client_id: r.client_id,
        scopes: r.scopes,
        resource: r.resource,
        status: String.to_existing_atom(r.status),
        subject_id: r.subject_id,
        interval: r.interval,
        expires_at: r.expires_at,
        last_polled_at: r.last_polled_at,
        inserted_at: r.inserted_at
      }
    end

    # The replaced refresh token's row, locked: a concurrent
    # `revoke_family/2` locks the family's rows before revoking them, so it
    # waits for this transaction and then revokes the new pair too; one
    # that ran first left the row revoked, and nothing is inserted.
    @impl true
    def put_rotated_tokens(%{repo: repo} = s, refresh_hash, tokens) do
      fence =
        from(t in S.Token,
          where: t.hash == ^refresh_hash and t.kind == "refresh" and is_nil(t.revoked_at),
          lock: "FOR UPDATE",
          select: t.id
        )

      {:ok, result} =
        repo.transaction(fn ->
          case repo.one(fence, prefix: s.prefix) do
            nil -> :revoked
            _ -> Enum.each(tokens, &(:ok = put_token(s, &1)))
          end
        end)

      result
    end

    @impl true
    def put_token(%{repo: repo} = s, %TokenRecord{} = t) do
      row = %S.Token{
        id: t.id,
        kind: to_string(t.kind),
        hash: t.hash,
        family_id: t.family_id,
        client_id: t.client_id,
        subject_id: t.subject_id,
        scopes: t.scopes,
        resource: t.resource,
        expires_at: DateTime.truncate(t.expires_at, :second),
        revoked_at: t.revoked_at,
        used_at: t.used_at,
        inserted_at: DateTime.truncate(t.inserted_at || DateTime.utc_now(), :second),
        jkt: t.jkt
      }

      {:ok, _} =
        repo.insert(row,
          on_conflict: {:replace_all_except, [:revoked_at, :used_at]},
          conflict_target: :id,
          prefix: s.prefix
        )

      :ok
    end

    @impl true
    def get_token(%{repo: repo} = s, kind, hash) do
      kind = to_string(kind)

      case repo.one(from(t in S.Token, where: t.hash == ^hash and t.kind == ^kind),
             prefix: s.prefix
           ) do
        nil -> :error
        r -> {:ok, token(r)}
      end
    end

    @impl true
    def consume_refresh(%{repo: repo} = s, hash) do
      query =
        from(t in S.Token,
          where: t.hash == ^hash and t.kind == "refresh" and is_nil(t.used_at),
          select: t
        )

      case repo.update_all(query, [set: [used_at: now()]], prefix: s.prefix) do
        {1, [row]} ->
          {:ok, token(%{row | used_at: nil})}

        {0, []} ->
          case repo.one(from(t in S.Token, where: t.hash == ^hash and t.kind == "refresh"),
                 prefix: s.prefix
               ) do
            nil -> :error
            row -> {:error, :used, token(row)}
          end
      end
    end

    @impl true
    def revoke_token(%{repo: repo} = s, id) do
      repo.update_all(
        from(t in S.Token, where: t.id == ^id and is_nil(t.revoked_at)),
        [set: [revoked_at: now()]],
        prefix: s.prefix
      )

      :ok
    end

    # A family born of a code (or a device grant) also revokes the code's
    # row, under its lock (see `put_code_tokens/3` and
    # `put_device_tokens/3`), and every family locks its tokens' rows
    # (see `put_rotated_tokens/3`), before the sweep. A pair being stored
    # for the code or a rotation either is refused, or is committed before
    # the sweep runs: the sweep is a statement of its own, and READ
    # COMMITTED gives it a snapshot taken after the locks were granted.
    # The rows are locked in `id` order, so two revocations of one family
    # cannot deadlock.
    @impl true
    def revoke_family(%{repo: repo} = s, family_id) do
      {:ok, :ok} =
        repo.transaction(fn ->
          repo.update_all(
            from(c in S.Code, where: c.hash == ^family_id and is_nil(c.revoked_at)),
            [set: [revoked_at: now()]],
            prefix: s.prefix
          )

          repo.update_all(
            from(g in S.DeviceGrant, where: g.hash == ^family_id and is_nil(g.revoked_at)),
            [set: [revoked_at: now()]],
            prefix: s.prefix
          )

          repo.all(
            from(t in S.Token,
              where: t.family_id == ^family_id,
              order_by: t.id,
              lock: "FOR UPDATE",
              select: t.id
            ),
            prefix: s.prefix
          )

          repo.update_all(
            from(t in S.Token, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
            [set: [revoked_at: now()]],
            prefix: s.prefix
          )

          :ok
        end)

      :ok
    end

    # The primary key makes the insert the check: a second insert of the
    # same key, from any node, inserts nothing.
    @impl true
    def once(%{repo: repo} = s, key, expires_at) do
      row = %{key: key, expires_at: DateTime.from_unix!(expires_at)}

      case repo.insert_all(S.Replay, [row], on_conflict: :nothing, prefix: s.prefix) do
        {1, _} -> :ok
        {0, _} -> :replayed
      end
    end

    @impl true
    def prune_once(%{repo: repo} = s, now) do
      now = DateTime.from_unix!(now)
      repo.delete_all(from(r in S.Replay, where: r.expires_at < ^now), prefix: s.prefix)
      :ok
    end

    @impl true
    def tokens_for_subject(%{repo: repo} = s, subject_id) do
      from(t in S.Token, where: t.subject_id == ^subject_id)
      |> repo.all(prefix: s.prefix)
      |> Enum.map(&token/1)
    end

    defp token(r) do
      %TokenRecord{
        id: r.id,
        kind: String.to_existing_atom(r.kind),
        hash: r.hash,
        family_id: r.family_id,
        client_id: r.client_id,
        subject_id: r.subject_id,
        scopes: r.scopes,
        resource: r.resource,
        expires_at: r.expires_at,
        revoked_at: r.revoked_at,
        used_at: r.used_at,
        inserted_at: r.inserted_at,
        jkt: r.jkt
      }
    end

    @impl true
    def put_consent(%{repo: repo} = s, %Consent{} = c) do
      row = %S.Consent{
        subject_id: c.subject_id,
        client_id: c.client_id,
        resource: c.resource,
        scopes: c.scopes,
        inserted_at: DateTime.truncate(c.inserted_at, :second)
      }

      {:ok, _} =
        repo.insert(row,
          on_conflict: {:replace, [:scopes, :inserted_at]},
          conflict_target: [:subject_id, :client_id, :resource],
          prefix: s.prefix
        )

      :ok
    end

    @impl true
    def get_consent(%{repo: repo} = s, subject_id, client_id, resource) do
      case repo.one(
             from(c in S.Consent,
               where:
                 c.subject_id == ^subject_id and c.client_id == ^client_id and
                   c.resource == ^resource
             ),
             prefix: s.prefix
           ) do
        nil ->
          :error

        r ->
          {:ok,
           %Consent{
             subject_id: r.subject_id,
             client_id: r.client_id,
             resource: r.resource,
             scopes: r.scopes,
             inserted_at: r.inserted_at
           }}
      end
    end

    @impl true
    def delete_consent(%{repo: repo} = s, subject_id, client_id, resource) do
      query =
        from(c in S.Consent, where: c.subject_id == ^subject_id and c.client_id == ^client_id)

      query = if resource == :all, do: query, else: where(query, [c], c.resource == ^resource)
      repo.delete_all(query, prefix: s.prefix)
      :ok
    end

    @impl true
    def prune(%{repo: repo} = s, now, before) do
      repo.delete_all(from(c in S.Code, where: c.expires_at <= ^now), prefix: s.prefix)
      repo.delete_all(from(p in S.PushedRequest, where: p.expires_at <= ^now), prefix: s.prefix)
      repo.delete_all(from(g in S.DeviceGrant, where: g.expires_at <= ^now), prefix: s.prefix)
      repo.delete_all(from(t in S.Token, where: t.expires_at <= ^now), prefix: s.prefix)
      repo.delete_all(from(r in S.Replay, where: r.expires_at < ^now), prefix: s.prefix)

      live =
        from(t in S.Token,
          where:
            t.kind == "refresh" and is_nil(t.revoked_at) and t.expires_at > ^now and
              t.subject_id == parent_as(:consent).subject_id and
              t.client_id == parent_as(:consent).client_id and
              t.resource == parent_as(:consent).resource,
          select: 1
        )

      repo.delete_all(
        from(c in S.Consent,
          as: :consent,
          where: c.inserted_at < ^before.consents and not exists(live)
        ),
        prefix: s.prefix
      )

      prune_unused_clients(s, now, before.unused_clients)
    end

    # What is left of the codes, pushed requests, device grants and tokens
    # is unexpired: a client with a code, a pushed request, a device
    # grant, an unrevoked token or a consent is in use.
    defp prune_unused_clients(%{repo: repo} = s, now, registered_before) do
      token =
        from(t in S.Token,
          where:
            t.client_id == parent_as(:client).id and is_nil(t.revoked_at) and
              t.expires_at > ^now,
          select: 1
        )

      consent = from(c in S.Consent, where: c.client_id == parent_as(:client).id, select: 1)
      code = from(c in S.Code, where: c.client_id == parent_as(:client).id, select: 1)
      device = from(g in S.DeviceGrant, where: g.client_id == parent_as(:client).id, select: 1)

      pushed =
        from(p in S.PushedRequest, where: p.client_id == parent_as(:client).id, select: 1)

      repo.delete_all(
        from(c in S.Client,
          as: :client,
          where:
            c.kind == "dynamic" and c.inserted_at < ^registered_before and
              not exists(token) and not exists(consent) and not exists(code) and
              not exists(device) and not exists(pushed)
        ),
        prefix: s.prefix
      )

      :ok
    end

    defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
