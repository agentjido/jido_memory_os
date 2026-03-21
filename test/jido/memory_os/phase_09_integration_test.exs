defmodule Jido.MemoryOS.Phase09IntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Memory.Actions.{Forget, Recall, Remember, Retrieve}
  alias Jido.Memory.Plugin
  alias Jido.Memory.ProviderContract
  alias Jido.Memory.ProviderRef
  alias Jido.Memory.Record
  alias Jido.Memory.Runtime
  alias Jido.Memory.Store.ETS
  alias Jido.MemoryOS.FrameworkAdapter.SingleAgent
  alias Jido.MemoryOS.{MemoryManager, Provider}

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    manager = :"phase9-memory-manager-#{unique}"
    target = %{id: "phase9-agent-#{unique}"}
    journal_path = Path.join(System.tmp_dir!(), "jido_memory_os_phase9_#{unique}.log")

    tables = %{
      short: :"jido_memory_os_phase9_#{unique}_short",
      mid: :"jido_memory_os_phase9_#{unique}_mid",
      long: :"jido_memory_os_phase9_#{unique}_long"
    }

    app_config = phase9_app_config(tables, journal_path)

    cleanup_tables(tables)
    File.rm(journal_path)

    start_supervised!({MemoryManager, name: manager, app_config: app_config}, id: manager)

    on_exit(fn ->
      cleanup_tables(tables)
      File.rm(journal_path)
    end)

    {:ok,
     manager: manager,
     target: target,
     tables: tables,
     app_config: app_config,
     provider: {Provider, [server: manager, app_config: app_config]}}
  end

  test "provider exposes metadata, child specs, and canonical capabilities", ctx do
    opts = [server: ctx.manager, app_config: ctx.app_config, framework_adapter: SingleAgent]
    manager = ctx.manager

    assert :ok = Provider.validate_config(opts)
    assert [child_spec] = Provider.child_specs(opts)
    assert child_spec.id == {Provider, ctx.manager}

    assert {:ok, meta} = Provider.init(opts)
    assert meta.provider == Provider
    assert meta.server == ctx.manager
    assert meta.framework.adapter == SingleAgent
    assert meta.capabilities.lifecycle.consolidate == true
    assert meta.capabilities.retrieval.explainable == true

    assert {:ok, capabilities} = Runtime.capabilities(ctx.target, provider: ctx.provider)
    assert capabilities.hooks.pre_turn == true

    assert {:ok, %{provider: Provider, server: ^manager}} =
             Runtime.info(ctx.target, [:provider, :server], provider: ctx.provider)
  end

  test "provider core callbacks and canonical runtime helpers work across tiers", ctx do
    assert {:ok, token_entry} =
             MemoryManager.issue_approval_token(
               ctx.manager,
               actor_id: ctx.target.id,
               actions: [:forget],
               reason: "phase9 contract"
             )

    assert {:ok, %{deleted?: true}} =
             ProviderContract.exercise_core_flow(
               ctx.provider,
               ctx.target,
               %{class: :episodic, kind: :event, text: "phase9 contract flow"},
               %{text_contains: "phase9 contract flow", tier_mode: :short, limit: 5},
               actor_id: ctx.target.id,
               approval_token: token_entry.token
             )

    assert {:ok, %Record{id: short_id}} =
             Runtime.remember(
               ctx.target,
               %{class: :episodic, kind: :event, text: "phase9 short memory"},
               provider: ctx.provider
             )

    assert {:ok, %Record{id: long_id}} =
             Provider.remember(
               ctx.target,
               %{class: :semantic, kind: :fact, text: "phase9 long memory"},
               server: ctx.manager,
               app_config: ctx.app_config,
               tier: :long
             )

    assert {:ok, %Record{id: ^short_id}} =
             Provider.get(ctx.target, short_id, server: ctx.manager, app_config: ctx.app_config)

    assert {:ok, %Record{id: ^long_id}} =
             Provider.get(ctx.target, long_id, server: ctx.manager, app_config: ctx.app_config)

    assert {:ok, [%Record{id: ^short_id}]} =
             Runtime.retrieve(
               ctx.target,
               %{text_contains: "short memory", tier_mode: :short, limit: 5},
               provider: ctx.provider
             )

    assert {:ok, explain} =
             Runtime.explain_retrieval(
               ctx.target,
               %{text_contains: "short memory", tier_mode: :short, limit: 5},
               provider: ctx.provider
             )

    assert explain.result_count >= 1

    assert {:ok, summary} = Runtime.consolidate(ctx.target, provider: ctx.provider)
    assert is_map(summary)
  end

  test "provider direct operations, governance, and turn hooks execute successfully", ctx do
    remember_opts = [server: ctx.manager, app_config: ctx.app_config, actor_id: ctx.target.id]

    assert {:ok, _record} =
             Provider.remember(
               ctx.target,
               %{class: :episodic, kind: :event, text: "phase9 audited memory"},
               remember_opts
             )

    assert {:ok, policy} = Provider.current_policy(server: ctx.manager, app_config: ctx.app_config)
    assert is_map(policy)

    assert {:ok, token_entry} =
             Provider.issue_approval_token(
               server: ctx.manager,
               actor_id: ctx.target.id,
               actions: [:forget],
               reason: "phase9 test"
             )

    assert is_binary(token_entry.token)

    assert {:ok, pre_turn} =
             Provider.pre_turn(
               ctx.target,
               server: ctx.manager,
               app_config: ctx.app_config,
               framework_adapter: SingleAgent,
               payload: %{query: "phase9 audited", memory_query: %{text_contains: "phase9", limit: 3}}
             )

    assert is_map(pre_turn)

    assert {:ok, post_turn} =
             Provider.post_turn(
               ctx.target,
               server: ctx.manager,
               app_config: ctx.app_config,
               framework_adapter: SingleAgent,
               payload: %{response_text: "phase9 post turn memory", chain_id: "chain:phase9"}
             )

    assert is_map(post_turn)

    assert {:ok, metrics} = Provider.metrics(server: ctx.manager)
    assert is_map(metrics)

    assert {:ok, audit_events} = Provider.audit_events(server: ctx.manager, limit: 20)
    assert audit_events != []

    assert {:ok, journal_events} = Provider.journal_events(server: ctx.manager, limit: 20)
    assert journal_events != []

    assert {:ok, cancelled} = Provider.cancel_pending(server: ctx.manager, agent_id: ctx.target.id)
    assert is_integer(cancelled)
  end

  test "common Jido.Memory plugin works over MemoryOS while recall compatibility stays intact", ctx do
    config = %{
      provider: {Provider, [server: ctx.manager, app_config: ctx.app_config]},
      capture_signal_patterns: ["ai.react.query"]
    }

    assert {:ok, plugin_state} = Plugin.mount(ctx.target, config)
    assert %ProviderRef{module: Provider} = plugin_state.provider

    context = %{agent: ctx.target, state: %{__memory__: plugin_state}}

    assert {:ok, %{last_memory_id: id}} =
             Remember.run(
               %{class: :episodic, kind: :event, text: "phase9 common plugin remember"},
               context
             )

    assert {:ok, %{memory_results: [%Record{id: ^id}]}} =
             Retrieve.run(%{text_contains: "common plugin remember", limit: 5}, context)

    assert {:ok, %{memory_results: [%Record{id: ^id}]}} =
             Recall.run(%{text_contains: "common plugin remember", limit: 5}, context)

    assert {:ok, token_entry} =
             MemoryManager.issue_approval_token(
               ctx.manager,
               actor_id: ctx.target.id,
               actions: [:forget],
               reason: "phase9 common plugin"
             )

    assert {:ok, %{last_memory_deleted?: true}} =
             Forget.run(%{id: id, approval_token: token_entry.token, actor_id: ctx.target.id}, context)

    signal =
      Jido.Signal.new!("ai.react.query", %{query: "phase9 captured query"}, source: "/phase9")

    agent = %{id: ctx.target.id, state: %{__memory__: plugin_state}}

    assert {:ok, :continue} = Plugin.handle_signal(signal, %{agent: agent})

    assert {:ok, [%Record{text: "phase9 captured query"}]} =
             Runtime.retrieve(agent, %{text_contains: "phase9 captured query", limit: 5})
  end

  defp phase9_app_config(tables, journal_path) do
    %{
      tiers: %{
        short: %{store: {ETS, [table: tables.short]}},
        mid: %{store: {ETS, [table: tables.mid]}},
        long: %{store: {ETS, [table: tables.long]}}
      },
      manager: %{
        journal_path: journal_path,
        replay_on_start: false
      },
      governance: %{
        approvals: %{
          enabled: true,
          required_actions: [:forget]
        },
        audit: %{
          enabled: true,
          max_events: 200
        }
      }
    }
  end

  defp cleanup_tables(tables) do
    Enum.each(tables, fn {_tier, table} ->
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)
  end
end
