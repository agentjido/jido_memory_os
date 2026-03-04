defmodule Jido.MemoryOS.LongTermStore.Postgres do
  @moduledoc """
  PostgreSQL-backed `LongTermStore` implementation.

  This backend stores `:long` tier records in a PostgreSQL table and supports
  the same basic CRUD/query semantics as the ETS default backend.

  ## Configuration

  Set `manager.long_term_backend` to this module, and provide backend options:

      manager: %{
        long_term_backend: Jido.MemoryOS.LongTermStore.Postgres,
        long_term_backend_opts: [
          conn: MyApp.Postgrex,               # registered Postgrex process (or pid)
          # OR conn_opts: [hostname: "localhost", ...] for ephemeral per-call connections
          table: "jido_memory_os_long_term",  # optional
          schema: "public",                   # optional
          ensure_table?: true                 # optional, defaults true
        ]
      }

  You can also pass `query_fun: &Postgrex.query/4` for custom query execution.
  """

  @behaviour Jido.MemoryOS.LongTermStore

  alias Jido.Memory.Query
  alias Jido.Memory.Record

  @default_table "jido_memory_os_long_term"
  @default_schema "public"
  @identifier_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @ready_key_prefix :jido_memory_os_postgres_ready

  @record_columns [
    "namespace",
    "id",
    "class",
    "kind",
    "text",
    "content",
    "tags",
    "source",
    "observed_at",
    "expires_at",
    "embedding",
    "metadata",
    "version"
  ]

  @impl true
  @spec remember(map() | struct(), map() | keyword(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def remember(_target, attrs, opts) do
    with {:ok, context} <- context(opts),
         {:ok, record} <- build_record(attrs, context.namespace, context.now),
         {:ok, result} <-
           with_connection(context, fn conn ->
             with :ok <- ensure_table(conn, context),
                  {:ok, result} <-
                    run_query(conn, context, upsert_sql(context), record_params(record)) do
               {:ok, result}
             end
           end),
         {:ok, [stored]} <- records_from_result(result, context.now) do
      {:ok, stored}
    end
  end

  @impl true
  @spec get(map() | struct(), String.t(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def get(_target, id, _opts) when not is_binary(id), do: {:error, :invalid_id}

  def get(_target, id, opts) do
    with {:ok, context} <- context(opts),
         {:ok, result} <-
           with_connection(context, fn conn ->
             with :ok <- ensure_table(conn, context),
                  {:ok, result} <-
                    run_query(conn, context, get_sql(context), [
                      context.namespace,
                      id,
                      context.now
                    ]) do
               {:ok, result}
             end
           end),
         {:ok, records} <- records_from_result(result, context.now) do
      case records do
        [record | _] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    end
  end

  @impl true
  @spec recall(map() | struct(), map() | keyword() | Query.t(), keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def recall(_target, query, opts) do
    with {:ok, context} <- context(opts),
         {:ok, query} <- normalize_query(query, context.namespace),
         {sql, params} <- recall_sql(context, query),
         {:ok, result} <-
           with_connection(context, fn conn ->
             with :ok <- ensure_table(conn, context),
                  {:ok, result} <- run_query(conn, context, sql, params) do
               {:ok, result}
             end
           end),
         {:ok, records} <- records_from_result(result, context.now) do
      {:ok, records}
    end
  end

  @impl true
  @spec forget(map() | struct(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def forget(_target, id, _opts) when not is_binary(id), do: {:error, :invalid_id}

  def forget(_target, id, opts) do
    with {:ok, context} <- context(opts),
         {:ok, result} <-
           with_connection(context, fn conn ->
             with :ok <- ensure_table(conn, context),
                  {:ok, _expired_pruned} <-
                    run_query(
                      conn,
                      context,
                      prune_one_expired_sql(context),
                      [context.namespace, id, context.now]
                    ),
                  {:ok, deleted} <-
                    run_query(
                      conn,
                      context,
                      forget_sql(context),
                      [context.namespace, id, context.now]
                    ) do
               {:ok, deleted}
             end
           end) do
      {:ok, num_rows(result) > 0}
    end
  end

  @impl true
  @spec prune(map() | struct(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune(_target, opts) do
    with {:ok, context} <- context(opts),
         {:ok, result} <-
           with_connection(context, fn conn ->
             with :ok <- ensure_table(conn, context),
                  {:ok, result} <-
                    run_query(conn, context, prune_sql(context), [context.namespace, context.now]) do
               {:ok, result}
             end
           end) do
      {:ok, max(num_rows(result), 0)}
    end
  end

  @spec context(keyword()) :: {:ok, map()} | {:error, term()}
  defp context(opts) when not is_list(opts), do: {:error, :invalid_long_term_backend_opts}

  defp context(opts) do
    with {:ok, namespace} <- required_binary(opts, :namespace),
         {:ok, query_fun} <- resolve_query_fun(opts),
         {:ok, conn_source} <- resolve_conn_source(opts),
         {:ok, table_ref, table_name} <- resolve_table(opts),
         {:ok, query_opts} <- keyword_option(opts, :query_opts, []) do
      {:ok,
       %{
         namespace: namespace,
         now: Keyword.get(opts, :now, System.system_time(:millisecond)),
         query_fun: query_fun,
         conn_source: conn_source,
         query_opts: query_opts,
         ensure_table?: Keyword.get(opts, :ensure_table?, true),
         table_ref: table_ref,
         table_name: table_name
       }}
    end
  end

  @spec resolve_query_fun(keyword()) ::
          {:ok, (term(), String.t(), list(), keyword() -> term())} | {:error, term()}
  defp resolve_query_fun(opts) do
    case Keyword.get(opts, :query_fun) do
      fun when is_function(fun, 4) ->
        {:ok, fun}

      nil ->
        case Code.ensure_loaded(Postgrex) do
          {:module, Postgrex} -> {:ok, &Postgrex.query/4}
          {:error, _reason} -> {:error, :postgrex_not_available}
        end

      value ->
        {:error, {:invalid_long_term_backend_option, :query_fun, value}}
    end
  end

  @spec resolve_conn_source(keyword()) ::
          {:ok, {:direct, term()} | {:conn_opts, keyword()}} | {:error, term()}
  defp resolve_conn_source(opts) do
    cond do
      Keyword.has_key?(opts, :conn) ->
        case Keyword.get(opts, :conn) do
          nil -> {:error, {:missing_long_term_backend_option, :conn}}
          conn -> {:ok, {:direct, conn}}
        end

      Keyword.has_key?(opts, :conn_opts) ->
        case Keyword.get(opts, :conn_opts) do
          conn_opts when is_list(conn_opts) ->
            if Keyword.keyword?(conn_opts) do
              {:ok, {:conn_opts, conn_opts}}
            else
              {:error, {:invalid_long_term_backend_option, :conn_opts, conn_opts}}
            end

          value ->
            {:error, {:invalid_long_term_backend_option, :conn_opts, value}}
        end

      true ->
        {:error, {:missing_long_term_backend_option, :conn}}
    end
  end

  @spec resolve_table(keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  defp resolve_table(opts) do
    table = Keyword.get(opts, :table, @default_table)
    schema = Keyword.get(opts, :schema, @default_schema)

    with {:ok, table} <- normalize_identifier(table, :table),
         {:ok, schema} <- normalize_identifier(schema, :schema) do
      {:ok, quoted_identifier(schema) <> "." <> quoted_identifier(table), table}
    end
  end

  @spec normalize_identifier(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_identifier(value, key) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@identifier_regex, value) do
      {:ok, value}
    else
      {:error, {:invalid_long_term_backend_option, key, value}}
    end
  end

  defp normalize_identifier(value, key),
    do: {:error, {:invalid_long_term_backend_option, key, value}}

  @spec quoted_identifier(String.t()) :: String.t()
  defp quoted_identifier(identifier), do: "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""

  @spec required_binary(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:missing_long_term_backend_option, key}}
    end
  end

  @spec keyword_option(keyword(), atom(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp keyword_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) ->
        if Keyword.keyword?(value) do
          {:ok, value}
        else
          {:error, {:invalid_long_term_backend_option, key, value}}
        end

      value ->
        {:error, {:invalid_long_term_backend_option, key, value}}
    end
  end

  @spec with_connection(map(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  defp with_connection(%{conn_source: {:direct, conn}}, function), do: function.(conn)

  defp with_connection(%{conn_source: {:conn_opts, conn_opts}}, function) do
    with {:ok, postgrex} <- ensure_postgrex_loaded(),
         {:ok, conn} <- postgrex.start_link(conn_opts) do
      try do
        function.(conn)
      after
        Process.exit(conn, :normal)
      end
    else
      {:error, reason} -> {:error, {:postgres_connection_failed, reason}}
    end
  end

  @spec ensure_postgrex_loaded() :: {:ok, module()} | {:error, term()}
  defp ensure_postgrex_loaded do
    case Code.ensure_loaded(Postgrex) do
      {:module, Postgrex} -> {:ok, Postgrex}
      {:error, _reason} -> {:error, :postgrex_not_available}
    end
  end

  @spec run_query(term(), map(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  defp run_query(conn, context, sql, params) do
    case context.query_fun.(conn, sql, params, context.query_opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:postgres_query_failed, reason}}
      other -> {:error, {:invalid_postgres_query_result, other}}
    end
  rescue
    error -> {:error, {:postgres_query_exception, error, __STACKTRACE__}}
  end

  @spec ensure_table(term(), map()) :: :ok | {:error, term()}
  defp ensure_table(_conn, %{ensure_table?: false}), do: :ok

  defp ensure_table(conn, context) do
    key = {@ready_key_prefix, context.table_ref}

    case :persistent_term.get(key, :not_ready) do
      :ready ->
        :ok

      _ ->
        with {:ok, _} <- run_query(conn, context, create_table_sql(context), []),
             {:ok, _} <- run_query(conn, context, create_time_index_sql(context), []),
             {:ok, _} <- run_query(conn, context, create_class_index_sql(context), []),
             {:ok, _} <- run_query(conn, context, create_expiry_index_sql(context), []),
             {:ok, _} <- run_query(conn, context, create_tags_index_sql(context), []) do
          :persistent_term.put(key, :ready)
          :ok
        end
    end
  end

  @spec build_record(map() | keyword(), String.t(), integer()) ::
          {:ok, Record.t()} | {:error, term()}
  defp build_record(attrs, namespace, now) when is_list(attrs),
    do: build_record(Map.new(attrs), namespace, now)

  defp build_record(attrs, namespace, now) when is_map(attrs) do
    attrs
    |> Map.put(:namespace, namespace)
    |> Map.put_new(:observed_at, now)
    |> Record.new(now: now)
  end

  defp build_record(_attrs, _namespace, _now), do: {:error, :invalid_attrs}

  @spec normalize_query(map() | keyword() | Query.t(), String.t()) ::
          {:ok, Query.t()} | {:error, term()}
  defp normalize_query(%Query{} = query, namespace) do
    if is_binary(query.namespace) and query.namespace != "" do
      {:ok, query}
    else
      {:ok, %{query | namespace: namespace}}
    end
  end

  defp normalize_query(query, namespace) when is_map(query) or is_list(query) do
    query
    |> normalize_query_map()
    |> Map.put_new(:namespace, namespace)
    |> Query.new()
  end

  defp normalize_query(_query, _namespace), do: {:error, :invalid_query}

  @spec normalize_query_map(map() | keyword()) :: map()
  defp normalize_query_map(%{} = query), do: query
  defp normalize_query_map(query) when is_list(query), do: Map.new(query)

  @spec recall_sql(map(), Query.t()) :: {String.t(), list()}
  defp recall_sql(context, %Query{} = query) do
    {clauses, params, index} = base_recall_filters(query.namespace, context.now)

    {clauses, params, index} =
      add_array_filter(
        clauses,
        params,
        index,
        "class = ANY(%s::text[])",
        to_class_strings(query.classes)
      )

    {clauses, params, index} =
      add_array_filter(
        clauses,
        params,
        index,
        "kind = ANY(%s::text[])",
        to_kind_strings(query.kinds)
      )

    {clauses, params, index} =
      add_array_filter(clauses, params, index, "tags && %s::text[]", query.tags_any)

    {clauses, params, index} =
      add_array_filter(clauses, params, index, "tags @> %s::text[]", query.tags_all)

    {clauses, params, index} = add_text_filter(clauses, params, index, query.text_contains)

    {clauses, params, index} =
      add_range_filter(clauses, params, index, "observed_at >= %s", query.since)

    {clauses, params, index} =
      add_range_filter(clauses, params, index, "observed_at <= %s", query.until)

    order =
      case query.order do
        :asc -> "ASC"
        _ -> "DESC"
      end

    sql =
      "SELECT #{Enum.join(@record_columns, ", ")} " <>
        "FROM #{context.table_ref} " <>
        "WHERE #{Enum.join(clauses, " AND ")} " <>
        "ORDER BY observed_at #{order}, id #{order} " <>
        "LIMIT $#{index}"

    {sql, params ++ [query.limit]}
  end

  @spec base_recall_filters(String.t(), integer()) :: {[String.t()], list(), pos_integer()}
  defp base_recall_filters(namespace, now),
    do: {["namespace = $1", "(expires_at IS NULL OR expires_at > $2)"], [namespace, now], 3}

  @spec add_array_filter([String.t()], list(), pos_integer(), String.t(), [String.t()]) ::
          {[String.t()], list(), pos_integer()}
  defp add_array_filter(clauses, params, index, _template, []), do: {clauses, params, index}

  defp add_array_filter(clauses, params, index, template, values) do
    clause = String.replace(template, "%s", "$#{index}")
    {clauses ++ [clause], params ++ [values], index + 1}
  end

  @spec add_text_filter([String.t()], list(), pos_integer(), String.t()) ::
          {[String.t()], list(), pos_integer()}
  defp add_text_filter(clauses, params, index, ""), do: {clauses, params, index}

  defp add_text_filter(clauses, params, index, text_contains) do
    escaped = "%" <> escape_like(text_contains) <> "%"
    clause = "COALESCE(text, content::text) ILIKE $#{index} ESCAPE '\\\\'"
    {clauses ++ [clause], params ++ [escaped], index + 1}
  end

  @spec add_range_filter([String.t()], list(), pos_integer(), String.t(), integer()) ::
          {[String.t()], list(), pos_integer()}
  defp add_range_filter(clauses, params, index, template, value) do
    clause = String.replace(template, "%s", "$#{index}")
    {clauses ++ [clause], params ++ [value], index + 1}
  end

  @spec escape_like(String.t()) :: String.t()
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @spec to_class_strings([Record.class()]) :: [String.t()]
  defp to_class_strings(classes), do: Enum.map(classes, &Atom.to_string/1)

  @spec to_kind_strings([Record.kind()]) :: [String.t()]
  defp to_kind_strings(kinds), do: Enum.map(kinds, &Record.kind_key/1)

  @spec records_from_result(term(), integer()) :: {:ok, [Record.t()]} | {:error, term()}
  defp records_from_result(result, now) do
    rows = rows_as_maps(result)

    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case row_to_record(row, now) do
        {:ok, record} -> {:cont, {:ok, acc ++ [record]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec rows_as_maps(term()) :: [map()]
  defp rows_as_maps(result) do
    rows = map_get(result, :rows, [])

    cond do
      rows == [] ->
        []

      is_list(rows) and is_map(hd(rows)) ->
        rows

      is_list(rows) and is_list(hd(rows)) ->
        columns = map_get(result, :columns, [])

        if is_list(columns) do
          Enum.map(rows, fn row ->
            Enum.zip(columns, row)
            |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
          end)
        else
          []
        end

      true ->
        []
    end
  end

  @spec row_to_record(map(), integer()) :: {:ok, Record.t()} | {:error, term()}
  defp row_to_record(row, now) do
    attrs = %{
      id: map_get(row, :id),
      namespace: map_get(row, :namespace),
      class: map_get(row, :class, :episodic),
      kind: map_get(row, :kind, :event),
      text: map_get(row, :text),
      content: normalize_json_like(map_get(row, :content, %{}), %{}),
      tags: normalize_tags(map_get(row, :tags, [])),
      source: map_get(row, :source),
      observed_at: normalize_integer(map_get(row, :observed_at), now),
      expires_at: normalize_optional_integer(map_get(row, :expires_at)),
      embedding: normalize_json_like(map_get(row, :embedding), nil),
      metadata: normalize_json_like(map_get(row, :metadata, %{}), %{}),
      version: normalize_integer(map_get(row, :version), 1)
    }

    Record.new(attrs, now: now)
  end

  @spec normalize_tags(term()) :: [String.t()]
  defp normalize_tags(tags) when is_list(tags) do
    Enum.map(tags, fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end)
  end

  defp normalize_tags(_), do: []

  @spec normalize_json_like(term(), term()) :: term()
  defp normalize_json_like(nil, fallback), do: fallback
  defp normalize_json_like(value, _fallback) when is_map(value), do: value
  defp normalize_json_like(value, _fallback) when is_list(value), do: value
  defp normalize_json_like(value, _fallback) when is_number(value), do: value
  defp normalize_json_like(value, _fallback) when is_boolean(value), do: value

  defp normalize_json_like(value, fallback) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> fallback
    end
  end

  defp normalize_json_like(_value, fallback), do: fallback

  @spec normalize_integer(term(), integer()) :: integer()
  defp normalize_integer(value, _fallback) when is_integer(value), do: value
  defp normalize_integer(_value, fallback), do: fallback

  @spec normalize_optional_integer(term()) :: integer() | nil
  defp normalize_optional_integer(value) when is_integer(value), do: value
  defp normalize_optional_integer(_value), do: nil

  @spec map_get(map(), atom(), term()) :: term()
  defp map_get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec num_rows(term()) :: integer()
  defp num_rows(result) do
    case map_get(result, :num_rows, 0) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  @spec record_params(Record.t()) :: list()
  defp record_params(%Record{} = record) do
    [
      record.namespace,
      record.id,
      Atom.to_string(record.class),
      Record.kind_key(record.kind),
      record.text,
      record.content,
      record.tags,
      record.source,
      record.observed_at,
      record.expires_at,
      record.embedding,
      record.metadata,
      record.version
    ]
  end

  @spec upsert_sql(map()) :: String.t()
  defp upsert_sql(context) do
    "INSERT INTO #{context.table_ref} " <>
      "(namespace, id, class, kind, text, content, tags, source, observed_at, expires_at, embedding, metadata, version) " <>
      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) " <>
      "ON CONFLICT (namespace, id) DO UPDATE SET " <>
      "class = EXCLUDED.class, kind = EXCLUDED.kind, text = EXCLUDED.text, " <>
      "content = EXCLUDED.content, tags = EXCLUDED.tags, source = EXCLUDED.source, " <>
      "observed_at = EXCLUDED.observed_at, expires_at = EXCLUDED.expires_at, " <>
      "embedding = EXCLUDED.embedding, metadata = EXCLUDED.metadata, version = EXCLUDED.version " <>
      "RETURNING #{Enum.join(@record_columns, ", ")}"
  end

  @spec get_sql(map()) :: String.t()
  defp get_sql(context) do
    "SELECT #{Enum.join(@record_columns, ", ")} " <>
      "FROM #{context.table_ref} " <>
      "WHERE namespace = $1 AND id = $2 AND (expires_at IS NULL OR expires_at > $3) " <>
      "LIMIT 1"
  end

  @spec forget_sql(map()) :: String.t()
  defp forget_sql(context) do
    "DELETE FROM #{context.table_ref} " <>
      "WHERE namespace = $1 AND id = $2 AND (expires_at IS NULL OR expires_at > $3)"
  end

  @spec prune_one_expired_sql(map()) :: String.t()
  defp prune_one_expired_sql(context) do
    "DELETE FROM #{context.table_ref} " <>
      "WHERE namespace = $1 AND id = $2 AND expires_at IS NOT NULL AND expires_at <= $3"
  end

  @spec prune_sql(map()) :: String.t()
  defp prune_sql(context) do
    "DELETE FROM #{context.table_ref} " <>
      "WHERE namespace = $1 AND expires_at IS NOT NULL AND expires_at <= $2"
  end

  @spec create_table_sql(map()) :: String.t()
  defp create_table_sql(context) do
    "CREATE TABLE IF NOT EXISTS #{context.table_ref} (" <>
      "namespace text NOT NULL, " <>
      "id text NOT NULL, " <>
      "class text NOT NULL, " <>
      "kind text NOT NULL, " <>
      "text text, " <>
      "content jsonb NOT NULL DEFAULT '{}'::jsonb, " <>
      "tags text[] NOT NULL DEFAULT ARRAY[]::text[], " <>
      "source text, " <>
      "observed_at bigint NOT NULL, " <>
      "expires_at bigint, " <>
      "embedding jsonb, " <>
      "metadata jsonb NOT NULL DEFAULT '{}'::jsonb, " <>
      "version integer NOT NULL DEFAULT 1, " <>
      "PRIMARY KEY (namespace, id)" <>
      ")"
  end

  @spec create_time_index_sql(map()) :: String.t()
  defp create_time_index_sql(context) do
    "CREATE INDEX IF NOT EXISTS #{index_name(context.table_name, "ns_time")} " <>
      "ON #{context.table_ref} (namespace, observed_at DESC, id DESC)"
  end

  @spec create_class_index_sql(map()) :: String.t()
  defp create_class_index_sql(context) do
    "CREATE INDEX IF NOT EXISTS #{index_name(context.table_name, "ns_class_time")} " <>
      "ON #{context.table_ref} (namespace, class, observed_at DESC, id DESC)"
  end

  @spec create_expiry_index_sql(map()) :: String.t()
  defp create_expiry_index_sql(context) do
    "CREATE INDEX IF NOT EXISTS #{index_name(context.table_name, "ns_expiry")} " <>
      "ON #{context.table_ref} (namespace, expires_at)"
  end

  @spec create_tags_index_sql(map()) :: String.t()
  defp create_tags_index_sql(context) do
    "CREATE INDEX IF NOT EXISTS #{index_name(context.table_name, "tags_gin")} " <>
      "ON #{context.table_ref} USING GIN (tags)"
  end

  @spec index_name(String.t(), String.t()) :: String.t()
  defp index_name(table_name, suffix) do
    base = "#{table_name}_#{suffix}"

    if String.length(base) <= 63 do
      quoted_identifier(base)
    else
      digest = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower) |> String.slice(0, 8)
      truncated = String.slice(base, 0, 63 - String.length(digest) - 1)
      quoted_identifier("#{truncated}_#{digest}")
    end
  end
end
