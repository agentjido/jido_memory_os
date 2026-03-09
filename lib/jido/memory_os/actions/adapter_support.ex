defmodule Jido.MemoryOS.Actions.AdapterSupport do
  @moduledoc false

  alias Jido.MemoryOS.{ErrorMapping, FrameworkAdapter}
  alias Jido.MemoryOS.FrameworkAdapter.SingleAgent
  import Jido.MemoryOS.Helpers, only: [normalize_keyword: 1, map_get: 2, map_get: 3]

  @required_callbacks [pre_turn: 3, post_turn: 3, normalize_error: 2]

  @spec memory_opt_keys() :: [atom()]
  def memory_opt_keys, do: FrameworkAdapter.memory_opt_keys()

  @spec default_adapter() :: module()
  def default_adapter, do: SingleAgent

  @spec resolve_adapter(map(), map(), atom()) ::
          {:ok, module()} | {:error, ErrorMapping.jido_error()}
  def resolve_adapter(params, context, operation) do
    framework = plugin_framework_config(context)

    adapter =
      map_get(params, :framework_adapter, map_get(framework, :adapter, default_adapter()))

    with {:ok, module} <- normalize_module(adapter, operation),
         {:ok, :loaded} <- ensure_module_loaded(module, operation),
         :ok <- ensure_callbacks(module, operation) do
      {:ok, module}
    end
  end

  @spec resolve_adapter_opts(map(), map(), [atom()]) :: keyword()
  def resolve_adapter_opts(params, context, extra_opt_keys \\ []) do
    framework = plugin_framework_config(context)

    base_opts =
      framework
      |> map_get(:opts, [])
      |> normalize_keyword()

    explicit_framework_opts =
      params
      |> map_get(:framework_opts, map_get(params, :framework_adapter_opts, []))
      |> normalize_keyword()

    direct_opts =
      Enum.reduce(memory_opt_keys() ++ extra_opt_keys, [], fn key, acc ->
        case map_get(params, key) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)
      |> Enum.reverse()

    base_opts
    |> Keyword.merge(explicit_framework_opts)
    |> Keyword.merge(direct_opts)
  end

  @spec build_turn_payload(map(), atom(), [atom()]) :: map()
  def build_turn_payload(params, explicit_key, drop_keys \\ []) do
    explicit_payload = map_get(params, explicit_key)

    if is_nil(explicit_payload) do
      params
      |> Map.drop(drop_keys)
      |> Map.drop(Enum.map(drop_keys, &Atom.to_string/1))
      |> FrameworkAdapter.normalize_map()
    else
      FrameworkAdapter.normalize_map(explicit_payload)
    end
  end

  @spec target(map(), map()) :: term()
  def target(params, context), do: map_get(params, :target, context)

  @spec normalize_adapter_error(module(), term(), atom()) :: term()
  def normalize_adapter_error(adapter, reason, phase) do
    if is_atom(adapter) and function_exported?(adapter, :normalize_error, 2) do
      adapter.normalize_error(reason, phase)
    else
      FrameworkAdapter.normalize_error(reason, phase)
    end
  end

  @spec framework_state(map()) :: map()
  def framework_state(context), do: plugin_framework_config(context)

  @spec plugin_framework_config(map()) :: map()
  defp plugin_framework_config(context) do
    context
    |> map_get(:state, %{})
    |> map_get(:__memory_os__, map_get(context, :__memory_os__, %{}))
    |> FrameworkAdapter.normalize_map()
    |> map_get(:framework, %{})
    |> FrameworkAdapter.normalize_map()
  end

  @spec normalize_module(term(), atom()) :: {:ok, module()} | {:error, ErrorMapping.jido_error()}
  defp normalize_module(module, _operation) when is_atom(module), do: {:ok, module}

  defp normalize_module(module, operation) do
    {:error, ErrorMapping.from_reason({:invalid_framework_adapter, module}, operation)}
  end

  @spec ensure_module_loaded(module(), atom()) ::
          {:ok, :loaded} | {:error, ErrorMapping.jido_error()}
  defp ensure_module_loaded(module, operation) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        {:ok, :loaded}

      {:error, reason} ->
        {:error,
         ErrorMapping.from_reason({:missing_framework_adapter_module, module, reason}, operation)}
    end
  end

  @spec ensure_callbacks(module(), atom()) :: :ok | {:error, ErrorMapping.jido_error()}
  defp ensure_callbacks(module, operation) do
    missing =
      Enum.reject(@required_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)

    if missing == [] do
      :ok
    else
      {:error,
       ErrorMapping.from_reason(
         {:invalid_framework_adapter_callbacks, module, missing},
         operation
       )}
    end
  end
end
