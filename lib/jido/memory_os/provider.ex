defmodule Jido.MemoryOS.Provider do
  @moduledoc """
  Canonical `jido_memory` provider bridge for MemoryOS.

  This exposes MemoryOS through the shared `Jido.Memory.Provider` contract
  while keeping the native `Jido.MemoryOS` facade and plugin available for
  advanced use cases.
  """

  @behaviour Jido.Memory.Provider
  @behaviour Jido.Memory.Capability.Lifecycle
  @behaviour Jido.Memory.Capability.ExplainableRetrieval
  @behaviour Jido.Memory.Capability.Operations
  @behaviour Jido.Memory.Capability.Governance
  @behaviour Jido.Memory.Capability.TurnHooks

  alias Jido.Memory.Runtime
  alias Jido.MemoryOS
  alias Jido.MemoryOS.Actions.{AdapterSupport, PostTurn, PreTurn}
  alias Jido.MemoryOS.Adapter.MemoryRuntime
  alias Jido.MemoryOS.Config
  alias Jido.MemoryOS.MemoryManager

  @capabilities %{
    core: true,
    retrieval: %{explainable: true},
    lifecycle: %{consolidate: true},
    operations: %{
      metrics: true,
      audit_events: true,
      journal_events: true,
      cancel_pending: true
    },
    governance: %{
      issue_approval_token: true,
      current_policy: true
    },
    hooks: %{
      pre_turn: true,
      post_turn: true
    }
  }

  @framework_callbacks [pre_turn: 3, post_turn: 3, normalize_error: 2]

  @type provider_opts :: keyword()

  @impl true
  def validate_config(opts) when is_list(opts) do
    with {:ok, _config} <- Config.validate(resolve_app_config(opts)),
         :ok <- validate_framework_adapter(Keyword.get(opts, :framework_adapter)),
         :ok <- validate_keyword_option(opts, :framework_adapter_opts),
         :ok <- validate_keyword_option(opts, :manager_opts) do
      :ok
    end
  end

  def validate_config(_opts), do: {:error, :invalid_provider_opts}

  @impl true
  def child_specs(opts) do
    server = resolve_server(opts)
    app_config = resolve_app_config(opts)

    [
      Supervisor.child_spec(
        {MemoryManager, [name: server, app_config: app_config]},
        id: {__MODULE__, server}
      )
    ]
  end

  @impl true
  def init(opts) do
    with :ok <- validate_config(opts),
         {:ok, config} <- Config.validate(resolve_app_config(opts)) do
      {:ok,
       %{
         provider: __MODULE__,
         server: resolve_server(opts),
         app_config: config,
         child_specs: child_specs(opts),
         framework: %{
           adapter: resolve_framework_adapter(opts),
           opts: normalize_keyword(Keyword.get(opts, :framework_adapter_opts, []))
         },
         capabilities: @capabilities
       }}
    end
  end

  @impl true
  def capabilities(provider_meta), do: Map.get(provider_meta, :capabilities, @capabilities)

  @impl true
  def remember(target, attrs, opts) do
    target
    |> sanitize_target()
    |> MemoryOS.remember(attrs, runtime_opts(opts))
    |> normalize_result()
  end

  @impl true
  def get(target, id, opts) when is_binary(id) do
    runtime_opts = runtime_opts(opts)
    target = sanitize_target(target)

    tiers =
      case Keyword.get(runtime_opts, :tier) do
        tier when tier in [:short, :mid, :long] -> [tier]
        _ -> [:short, :mid, :long]
      end

    fetch_record(target, id, runtime_opts, tiers)
  end

  def get(_target, _id, _opts), do: {:error, :invalid_id}

  @impl true
  def retrieve(target, query, opts) do
    target
    |> sanitize_target()
    |> MemoryOS.retrieve(query, runtime_opts(opts))
    |> normalize_result()
  end

  @impl true
  def forget(target, id, opts) when is_binary(id) do
    target
    |> sanitize_target()
    |> MemoryOS.forget(id, runtime_opts(opts))
    |> normalize_result()
  end

  def forget(_target, _id, _opts), do: {:error, :invalid_id}

  @impl true
  def prune(target, opts) do
    target
    |> sanitize_target()
    |> MemoryOS.prune(runtime_opts(opts))
    |> normalize_result()
  end

  @impl true
  def info(provider_meta, :all), do: {:ok, provider_meta}

  def info(provider_meta, fields) when is_list(fields) do
    {:ok, Map.take(provider_meta, fields)}
  end

  def info(_provider_meta, _fields), do: {:error, :invalid_info_fields}

  @impl true
  def consolidate(target, opts) do
    target
    |> sanitize_target()
    |> MemoryOS.consolidate(runtime_opts(opts))
    |> normalize_result()
  end

  @impl true
  def explain_retrieval(target, query, opts) do
    target
    |> sanitize_target()
    |> MemoryOS.explain_retrieval(query, runtime_opts(opts))
    |> normalize_result()
  end

  @impl true
  def metrics(opts) do
    MemoryManager.metrics(resolve_server(runtime_opts(opts)))
  end

  @impl true
  def audit_events(opts) do
    runtime_opts = runtime_opts(opts)
    server = resolve_server(runtime_opts)
    MemoryManager.audit_events(server, keyword_subset(runtime_opts, [:limit]))
  end

  @impl true
  def journal_events(opts) do
    runtime_opts = runtime_opts(opts)
    server = resolve_server(runtime_opts)
    MemoryManager.journal_events(server, keyword_subset(runtime_opts, [:limit]))
  end

  @impl true
  def cancel_pending(opts) do
    runtime_opts = runtime_opts(opts)
    server = resolve_server(runtime_opts)
    MemoryManager.cancel_pending(server, keyword_subset(runtime_opts, [:agent_id, :operation]))
  end

  @impl true
  def issue_approval_token(opts) do
    runtime_opts = runtime_opts(opts)
    server = resolve_server(runtime_opts)

    runtime_opts
    |> Keyword.drop([:provider_opts, :server, :manager, :app_config, :framework_adapter, :framework_adapter_opts])
    |> then(&MemoryManager.issue_approval_token(server, &1))
  end

  @impl true
  def current_policy(opts) do
    runtime_opts = runtime_opts(opts)
    server = resolve_server(runtime_opts)

    case MemoryManager.current_config(server) do
      {:ok, config} ->
        {:ok, get_in(config, [:governance, :policy]) || %{}}

      {:error, _reason} ->
        with {:ok, config} <- Config.validate(resolve_app_config(runtime_opts)) do
          {:ok, get_in(config, [:governance, :policy]) || %{}}
        end
    end
  end

  @impl true
  def pre_turn(target, opts) do
    run_turn_hook(PreTurn, target, opts, :turn_input, :memory_pre_turn)
  end

  @impl true
  def post_turn(target, opts) do
    run_turn_hook(PostTurn, target, opts, :turn_output, :memory_post_turn)
  end

  defp fetch_record(_target, _id, _runtime_opts, []), do: {:error, :not_found}

  defp fetch_record(target, id, runtime_opts, [tier | rest]) do
    lookup_opts = Keyword.put(runtime_opts, :tier, tier)

    with {:ok, context} <- MemoryRuntime.resolve_context(target, lookup_opts) do
      case Runtime.get(target, id, namespace: context.namespace, store: context.store) do
        {:ok, record} ->
          {:ok, record}

        {:error, :not_found} ->
          fetch_record(target, id, runtime_opts, rest)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, normalize_reason(reason)}
    end
  end

  defp run_turn_hook(action, target, opts, payload_key, result_key) do
    runtime_opts = runtime_opts(opts)
    target = sanitize_target(target)

    params =
      runtime_opts
      |> Keyword.put_new(:target, target)
      |> Keyword.put_new(payload_key, Keyword.get(runtime_opts, :payload, %{}))
      |> Keyword.put_new(:memory_result_key, result_key)
      |> Map.new()

    context = %{
      __memory_os__: %{
        framework: %{
          adapter: resolve_framework_adapter(runtime_opts),
          opts: normalize_keyword(Keyword.get(runtime_opts, :framework_adapter_opts, []))
        }
      }
    }

    case action.run(params, context) do
      {:ok, result} ->
        case Map.fetch(result, result_key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :invalid_turn_hook_result}
        end

      {:error, reason} ->
        {:error, normalize_reason(reason)}
    end
  end

  defp runtime_opts(opts) do
    provider_opts = normalize_keyword(Keyword.get(opts, :provider_opts, []))

    opts
    |> Keyword.drop([:provider_opts])
    |> then(&Keyword.merge(provider_opts, &1))
  end

  defp resolve_server(opts) do
    Keyword.get(opts, :server, Keyword.get(opts, :manager, MemoryManager))
  end

  defp resolve_app_config(opts) do
    Keyword.get(opts, :app_config, Config.app_config())
  end

  defp resolve_framework_adapter(opts) do
    Keyword.get(opts, :framework_adapter, AdapterSupport.default_adapter())
  end

  defp validate_framework_adapter(nil), do: :ok

  defp validate_framework_adapter(module) when is_atom(module) do
    with {:module, loaded} <- Code.ensure_loaded(module),
         :ok <- ensure_framework_callbacks(loaded) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_framework_adapter(_module), do: {:error, :invalid_framework_adapter}

  defp ensure_framework_callbacks(module) do
    missing =
      Enum.reject(@framework_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)

    if missing == [] do
      :ok
    else
      {:error, {:invalid_framework_adapter_callbacks, module, missing}}
    end
  end

  defp validate_keyword_option(opts, key) do
    case Keyword.get(opts, key, []) do
      value when is_list(value) -> :ok
      _ -> {:error, {:invalid_provider_option, key}}
    end
  end

  defp normalize_result({:ok, _value} = ok), do: ok
  defp normalize_result({:error, reason}), do: {:error, normalize_reason(reason)}

  defp normalize_reason(%Jido.Error.ValidationError{details: details} = error) do
    case detail_code(details) do
      :namespace_required -> :namespace_required
      :invalid_query -> :invalid_query
      :invalid_id -> :invalid_id
      :invalid_tier -> {:invalid_tier, detail_value(details, :tier)}
      _ -> error
    end
  end

  defp normalize_reason(%Jido.Error.ExecutionError{details: details} = error) do
    case detail_code(details) do
      :not_found -> :not_found
      _ -> error
    end
  end

  defp normalize_reason(reason), do: reason

  defp detail_code(details), do: detail_value(details, :code)

  defp detail_value(details, key) when is_map(details) do
    Map.get(details, key, Map.get(details, Atom.to_string(key)))
  end

  defp detail_value(_details, _key), do: nil

  defp normalize_keyword(opts) when is_list(opts), do: opts
  defp normalize_keyword(%{} = opts), do: Enum.to_list(opts)
  defp normalize_keyword(_opts), do: []

  defp sanitize_target(%{state: %{} = state} = target) do
    %{target | state: Map.delete(state, Runtime.plugin_state_key())}
  end

  defp sanitize_target(%{agent: %{state: %{} = state} = agent} = target) do
    %{target | agent: %{agent | state: Map.delete(state, Runtime.plugin_state_key())}}
  end

  defp sanitize_target(target), do: target

  defp keyword_subset(opts, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> [{key, value} | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end
end
