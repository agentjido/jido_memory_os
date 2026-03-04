defmodule Jido.MemoryOS.LongTermStore.PostgresTest do
  use ExUnit.Case, async: true

  alias Jido.MemoryOS.LongTermStore.Postgres

  test "remember persists one record via query_fun" do
    test_pid = self()

    query_fun = fn _conn, sql, params, _query_opts ->
      send(test_pid, {:sql, sql, params})

      {:ok,
       %{
         num_rows: 1,
         columns: [
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
         ],
         rows: [params]
       }}
    end

    opts = [namespace: "agent:test:long", conn: :fake, ensure_table?: false, query_fun: query_fun]

    assert {:ok, record} =
             Postgres.remember(
               %{id: "agent-test"},
               %{class: :semantic, kind: :fact, text: "postgres remember", tags: ["db"]},
               opts
             )

    assert record.namespace == "agent:test:long"
    assert record.class == :semantic
    assert record.kind == "fact"
    assert record.text == "postgres remember"
    assert record.tags == ["db"]

    assert_receive {:sql, sql, _params}
    assert String.starts_with?(sql, "INSERT INTO")
  end

  test "get returns one record from row map result" do
    query_fun = fn _conn, _sql, _params, _query_opts ->
      {:ok,
       %{
         num_rows: 1,
         rows: [
           %{
             "namespace" => "agent:test:long",
             "id" => "mem_1",
             "class" => "semantic",
             "kind" => "fact",
             "text" => "postgres get",
             "content" => %{},
             "tags" => ["db"],
             "source" => "test",
             "observed_at" => 1_000,
             "expires_at" => nil,
             "embedding" => nil,
             "metadata" => %{},
             "version" => 1
           }
         ]
       }}
    end

    opts = [
      namespace: "agent:test:long",
      conn: :fake,
      ensure_table?: false,
      query_fun: query_fun,
      now: 2_000
    ]

    assert {:ok, record} = Postgres.get(%{id: "agent-test"}, "mem_1", opts)
    assert record.id == "mem_1"
    assert record.namespace == "agent:test:long"
  end

  test "recall normalizes map query and returns records" do
    test_pid = self()

    query_fun = fn _conn, sql, _params, _query_opts ->
      send(test_pid, {:sql, sql})

      {:ok,
       %{
         num_rows: 1,
         rows: [
           %{
             "namespace" => "agent:test:long",
             "id" => "mem_2",
             "class" => "semantic",
             "kind" => "fact",
             "text" => "postgres recall",
             "content" => %{},
             "tags" => ["db"],
             "source" => nil,
             "observed_at" => 1_234,
             "expires_at" => nil,
             "embedding" => nil,
             "metadata" => %{},
             "version" => 1
           }
         ]
       }}
    end

    opts = [namespace: "agent:test:long", conn: :fake, ensure_table?: false, query_fun: query_fun]

    assert {:ok, [record]} =
             Postgres.recall(
               %{id: "agent-test"},
               %{classes: [:semantic], text_contains: "postgres", limit: 5, order: :desc},
               opts
             )

    assert record.id == "mem_2"
    assert_receive {:sql, sql}
    assert String.contains?(sql, "ORDER BY observed_at DESC, id DESC")
  end

  test "forget deletes active row and returns true" do
    test_pid = self()

    query_fun = fn _conn, sql, _params, _query_opts ->
      send(test_pid, {:sql, sql})

      cond do
        String.contains?(sql, "expires_at IS NOT NULL AND expires_at <= $3") ->
          {:ok, %{num_rows: 0}}

        String.starts_with?(sql, "DELETE FROM") ->
          {:ok, %{num_rows: 1}}

        true ->
          {:error, :unexpected_sql}
      end
    end

    opts = [namespace: "agent:test:long", conn: :fake, ensure_table?: false, query_fun: query_fun]
    assert {:ok, true} = Postgres.forget(%{id: "agent-test"}, "mem_3", opts)
    assert_receive {:sql, _}
    assert_receive {:sql, _}
  end

  test "prune deletes expired rows in namespace" do
    query_fun = fn _conn, sql, _params, _query_opts ->
      assert String.starts_with?(sql, "DELETE FROM")
      {:ok, %{num_rows: 3}}
    end

    opts = [namespace: "agent:test:long", conn: :fake, ensure_table?: false, query_fun: query_fun]
    assert {:ok, 3} = Postgres.prune(%{id: "agent-test"}, opts)
  end

  test "missing connection option returns validation error" do
    query_fun = fn _conn, _sql, _params, _query_opts -> {:ok, %{num_rows: 0}} end

    assert {:error, {:missing_long_term_backend_option, :conn}} =
             Postgres.prune(%{id: "agent-test"},
               namespace: "agent:test:long",
               query_fun: query_fun
             )
  end

  test "invalid table identifier is rejected" do
    query_fun = fn _conn, _sql, _params, _query_opts -> {:ok, %{num_rows: 0}} end

    assert {:error, {:invalid_long_term_backend_option, :table, "bad-name"}} =
             Postgres.prune(%{id: "agent-test"},
               namespace: "agent:test:long",
               conn: :fake,
               query_fun: query_fun,
               table: "bad-name"
             )
  end
end
