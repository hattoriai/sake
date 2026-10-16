if Code.ensure_loaded?(Ecto.Query) do
  defmodule Sake.Auth.Store.Ecto do
    @moduledoc """
    The Ecto store: `store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}` with
    the tables from `Sake.Auth.Migration`. Tested on Postgres.
    """
    @behaviour Sake.Auth.Store
    import Ecto.Query

    alias Sake.Auth.{Client, Code, Consent, TokenRecord}
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
        application_type: c.application_type
      }

      {:ok, _} =
        repo.insert(row, on_conflict: :replace_all, conflict_target: :id, prefix: s.prefix)

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
        application_type: r.application_type
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
        expires_at: DateTime.truncate(c.expires_at, :second)
      }

      {:ok, _} = repo.insert(row, prefix: s.prefix)
      :ok
    end

    @impl true
    def consume_code(%{repo: repo} = s, hash) do
      case repo.delete_all(from(c in S.Code, where: c.hash == ^hash, select: c), prefix: s.prefix) do
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
             expires_at: r.expires_at
           }}

        _ ->
          :error
      end
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

    @impl true
    def revoke_family(%{repo: repo} = s, family_id) do
      repo.update_all(
        from(t in S.Token, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
        [set: [revoked_at: now()]],
        prefix: s.prefix
      )

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
    def prune(%{repo: repo} = s, now, consents_before) do
      repo.delete_all(from(c in S.Code, where: c.expires_at <= ^now), prefix: s.prefix)
      repo.delete_all(from(t in S.Token, where: t.expires_at <= ^now), prefix: s.prefix)

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
          where: c.inserted_at < ^consents_before and not exists(live)
        ),
        prefix: s.prefix
      )

      :ok
    end

    defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
