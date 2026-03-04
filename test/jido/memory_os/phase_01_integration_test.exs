defmodule Jido.MemoryOS.Phase01IntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.MemoryOS.{Compatibility, Config, MemoryManager, Metadata}

  @short_table :jido_memory_os_test_short
  @mid_table :jido_memory_os_test_mid
  @long_table :jido_memory_os_test_long

  setup do
    Enum.each([@short_table, @mid_table, @long_table], fn table ->
      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end
    end)

    :ok
  end

  test "application boots manager/supervision and loads validated config" do
    assert Process.whereis(Jido.MemoryOS.Supervisor)
    assert Process.whereis(Jido.MemoryOS.MemoryManager)
    assert Process.whereis(Jido.MemoryOS.ManagerWorkers)
    assert Process.whereis(Jido.MemoryOS.MaintenanceSupervisor)

    assert {:ok, config} = MemoryManager.current_config()
    assert config.namespace_template == "agent:%{agent_id}:%{tier}"
    assert is_map(config.tiers)
    assert is_map(config.retrieval)
    assert config.manager.long_term_backend == Jido.MemoryOS.LongTermStore.ETS
  end

  test "adapter smoke path supports remember/retrieve/forget/prune with wrapped runtime" do
    target = %{id: "phase1-smoke-agent"}
    opts = [tier: :short, correlation_id: "phase1-smoke", tiers: tier_store_overrides()]

    {:ok, first} =
      Jido.MemoryOS.remember(
        target,
        %{
          class: :semantic,
          kind: :fact,
          text: "phase1 smoke",
          tags: ["phase1"],
          expires_at: System.system_time(:millisecond) - 1
        },
        opts
      )

    assert first.namespace == "agent:phase1-smoke-agent:short"
    assert get_in(first.metadata, ["mem_os", "tier"]) == "short"
    assert get_in(first.metadata, ["mem_os_trace", "correlation_id"]) == "phase1-smoke"

    {:ok, second} =
      Jido.MemoryOS.remember(
        target,
        %{
          class: :semantic,
          kind: :fact,
          text: "phase1 smoke keeps",
          tags: ["phase1"]
        },
        opts
      )

    assert {:ok, results} = Jido.MemoryOS.retrieve(target, %{text_contains: "phase1"}, opts)
    assert Enum.any?(results, &(&1.id == second.id))

    assert {:ok, count} = Jido.MemoryOS.prune(target, opts)
    assert count >= 1

    assert {:ok, true} = Jido.MemoryOS.forget(target, second.id, opts)
    assert {:ok, false} = Jido.MemoryOS.forget(target, second.id, opts)
  end

  test "tier namespace and store resolution are deterministic" do
    target = %{id: "phase1-mid-agent"}
    opts = [tier: :mid, tiers: tier_store_overrides()]

    assert {:ok, record} =
             Jido.MemoryOS.remember(
               target,
               %{class: :episodic, kind: :event, text: "mid tier"},
               opts
             )

    assert record.namespace == "agent:phase1-mid-agent:mid"
    records_table = :"#{@mid_table}_records"
    assert :ets.whereis(records_table) != :undefined
    assert [{{_, _}, _}] = :ets.lookup(records_table, {record.namespace, record.id})
  end

  test "long tier uses built-in long-term backend by default" do
    target = %{id: "phase1-long-default-agent"}
    opts = [tier: :long, correlation_id: "phase1-long-default", tiers: tier_store_overrides()]

    assert {:ok, record} =
             Jido.MemoryOS.remember(
               target,
               %{class: :semantic, kind: :fact, text: "phase1 long default"},
               opts
             )

    assert record.namespace == "agent:phase1-long-default-agent:long"

    assert {:ok, results} =
             Jido.MemoryOS.retrieve(target, %{text_contains: "phase1 long default"}, opts)

    assert Enum.any?(results, &(&1.id == record.id))
  end

  test "metadata encoder/decoder roundtrip preserves lifecycle fields with defaults" do
    attrs = %{metadata: %{"source" => "test"}}

    {:ok, encoded} =
      Metadata.encode_attrs(attrs, %{
        tier: :mid,
        chain_id: "chain-1",
        segment_id: "segment-2",
        page_id: "page-3",
        heat: 0.33,
        promotion_score: 0.77,
        last_accessed_at: 1234,
        consolidation_version: 2,
        persona_keys: ["ops", "alerts"]
      })

    assert {:ok, decoded} = Metadata.decode_metadata(encoded.metadata)
    assert decoded.tier == :mid
    assert decoded.chain_id == "chain-1"
    assert decoded.segment_id == "segment-2"
    assert decoded.page_id == "page-3"
    assert decoded.heat == 0.33
    assert decoded.promotion_score == 0.77
    assert decoded.last_accessed_at == 1234
    assert decoded.consolidation_version == 2
    assert decoded.persona_keys == ["ops", "alerts"]

    assert {:ok, defaults} = Metadata.decode_metadata(%{})
    assert defaults.tier == :short
    assert defaults.persona_keys == []
  end

  test "config validation returns path-aware structured errors" do
    assert {:error, errors} =
             Config.validate(%{
               "unexpected" => 1,
               "tiers" => %{"short" => %{"max_records" => 0}}
             })

    assert Enum.any?(errors, fn error ->
             error.path == ["unexpected"] and error.code == :unknown_field
           end)

    assert Enum.any?(errors, fn error ->
             error.path == [:tiers, :short, :max_records] and error.code == :invalid_type
           end)
  end

  defmodule IncompleteRuntime do
    def remember(_target, _attrs, _opts), do: {:ok, :noop}
  end

  defmodule RecordingLongTermStore do
    @behaviour Jido.MemoryOS.LongTermStore

    alias Jido.MemoryOS.LongTermStore.ETS

    @impl true
    def remember(target, attrs, opts) do
      notify(opts, :remember)
      ETS.remember(target, attrs, opts)
    end

    @impl true
    def get(target, id, opts) do
      notify(opts, :get)
      ETS.get(target, id, opts)
    end

    @impl true
    def recall(target, query, opts) do
      notify(opts, :recall)
      ETS.recall(target, query, opts)
    end

    @impl true
    def forget(target, id, opts) do
      notify(opts, :forget)
      ETS.forget(target, id, opts)
    end

    @impl true
    def prune(target, opts) do
      notify(opts, :prune)
      ETS.prune(target, opts)
    end

    defp notify(opts, operation) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:long_term_backend_called, operation, Keyword.get(opts, :tier)})
      end
    end
  end

  test "compatibility guards detect missing runtime capabilities" do
    assert {:ok, _version} = Compatibility.validate_jido_memory_version()
    assert :ok = Compatibility.validate_required_capabilities(Jido.Memory.Runtime)
    assert :ok = Compatibility.validate_runtime_contract()

    assert {:error, {:missing_runtime_capabilities, IncompleteRuntime, missing}} =
             Compatibility.validate_required_capabilities(IncompleteRuntime)

    assert {:get, 3} in missing
    assert {:prune_expired, 2} in missing
  end

  test "adapter emits native Jido errors for invalid input" do
    target = %{id: "phase1-error-agent"}
    opts = [tier: :short, tiers: tier_store_overrides()]

    assert {:error, %Jido.Error.ValidationError{} = error} =
             Jido.MemoryOS.retrieve(target, :invalid_query_shape, opts)

    assert error.kind == :input
    assert error.subject == :query

    assert {:error, %Jido.Error.ValidationError{} = tier_error} =
             Jido.MemoryOS.remember(target, %{class: :semantic, text: "x"}, tier: :unknown)

    assert tier_error.subject == :tier
  end

  test "long tier routes through configured long-term backend behavior" do
    target = %{id: "phase1-long-custom-agent"}

    opts = [
      tier: :long,
      correlation_id: "phase1-long-custom",
      tiers: tier_store_overrides(),
      long_term_backend: RecordingLongTermStore,
      long_term_backend_opts: [test_pid: self()]
    ]

    assert {:ok, record} =
             Jido.MemoryOS.remember(
               target,
               %{class: :semantic, kind: :fact, text: "phase1 long custom"},
               opts
             )

    assert_receive {:long_term_backend_called, :remember, :long}

    assert {:ok, results} =
             Jido.MemoryOS.retrieve(target, %{text_contains: "phase1 long custom"}, opts)

    assert Enum.any?(results, &(&1.id == record.id))
    assert_receive {:long_term_backend_called, :recall, :long}

    assert {:ok, true} = Jido.MemoryOS.forget(target, record.id, opts)
    assert_receive {:long_term_backend_called, :forget, :long}

    assert {:ok, pruned} = Jido.MemoryOS.prune(target, opts)
    assert is_integer(pruned)
    assert_receive {:long_term_backend_called, :prune, :long}
  end

  test "long tier backend callback contract errors map to config validation errors" do
    target = %{id: "phase1-long-contract-agent"}

    opts = [
      tier: :long,
      correlation_id: "phase1-long-contract",
      tiers: tier_store_overrides(),
      long_term_backend: IncompleteRuntime
    ]

    assert {:error, %Jido.Error.ValidationError{} = error} =
             Jido.MemoryOS.remember(
               target,
               %{class: :semantic, kind: :fact, text: "phase1 invalid backend"},
               opts
             )

    assert error.kind == :config
    assert error.subject == IncompleteRuntime
  end

  defp tier_store_overrides do
    %{
      short: %{store: {Jido.Memory.Store.ETS, [table: @short_table]}},
      mid: %{store: {Jido.Memory.Store.ETS, [table: @mid_table]}},
      long: %{store: {Jido.Memory.Store.ETS, [table: @long_table]}}
    }
  end
end
