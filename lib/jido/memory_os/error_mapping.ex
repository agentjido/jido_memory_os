defmodule Jido.MemoryOS.ErrorMapping do
  @moduledoc """
  Maps MemoryOS/internal reasons to native `Jido.Error` structs.
  """

  alias Jido.MemoryOS.ConfigError

  @type jido_error ::
          Jido.Error.ValidationError.t()
          | Jido.Error.ExecutionError.t()
          | Jido.Error.RoutingError.t()
          | Jido.Error.TimeoutError.t()
          | Jido.Error.CompensationError.t()
          | Jido.Error.InternalError.t()

  @doc """
  Converts arbitrary reason terms into typed Jido errors.
  """
  @spec from_reason(term(), atom()) :: jido_error()
  def from_reason(reason, operation) do
    case reason do
      {:error, nested} ->
        from_reason(nested, operation)

      :namespace_required ->
        Jido.Error.validation_error("namespace could not be resolved",
          kind: :input,
          subject: :namespace,
          details: details(operation, reason, %{code: :namespace_required})
        )

      :invalid_query ->
        Jido.Error.validation_error("query payload is invalid",
          kind: :input,
          subject: :query,
          details: details(operation, reason, %{code: :invalid_query})
        )

      :invalid_id ->
        Jido.Error.validation_error("record id is invalid",
          kind: :input,
          subject: :id,
          details: details(operation, reason, %{code: :invalid_id})
        )

      {:invalid_tier, tier} ->
        Jido.Error.validation_error("invalid memory tier",
          kind: :input,
          subject: :tier,
          details: details(operation, reason, %{code: :invalid_tier, tier: tier})
        )

      {:invalid_long_term_backend, backend} ->
        Jido.Error.validation_error("long-term backend must be a module",
          kind: :config,
          subject: :long_term_backend,
          details:
            details(operation, reason, %{code: :invalid_long_term_backend, backend: backend})
        )

      {:invalid_long_term_backend_callbacks, module, missing} ->
        Jido.Error.validation_error("long-term backend is missing required callbacks",
          kind: :config,
          subject: module,
          details:
            details(operation, reason, %{
              code: :invalid_long_term_backend_callbacks,
              missing_callbacks: missing
            })
        )

      {:missing_long_term_backend_module, module, reason_value} ->
        Jido.Error.validation_error("long-term backend module could not be loaded",
          kind: :config,
          subject: module,
          details:
            details(operation, reason, %{
              code: :missing_long_term_backend_module,
              load_reason: reason_value
            })
        )

      :invalid_long_term_backend_opts ->
        Jido.Error.validation_error("long-term backend options must be a keyword list",
          kind: :config,
          subject: :long_term_backend_opts,
          details: details(operation, reason, %{code: :invalid_long_term_backend_opts})
        )

      {:missing_long_term_backend_option, key} ->
        Jido.Error.validation_error("long-term backend context is missing required option",
          kind: :config,
          subject: key,
          details:
            details(operation, reason, %{
              code: :missing_long_term_backend_option,
              missing_option: key
            })
        )

      {:invalid_long_term_backend_option, key, value} ->
        Jido.Error.validation_error("long-term backend option is invalid",
          kind: :config,
          subject: key,
          details:
            details(operation, reason, %{
              code: :invalid_long_term_backend_option,
              option: key,
              value: value
            })
        )

      :postgrex_not_available ->
        Jido.Error.validation_error("Postgrex dependency is not available",
          kind: :config,
          subject: :long_term_backend,
          details: details(operation, reason, %{code: :postgrex_not_available})
        )

      {:postgres_connection_failed, reason_value} ->
        Jido.Error.execution_error("failed to connect to PostgreSQL backend",
          phase: :execution,
          details:
            details(operation, reason, %{
              code: :postgres_connection_failed,
              connection_reason: reason_value
            })
        )

      {:postgres_query_failed, reason_value} ->
        Jido.Error.execution_error("PostgreSQL backend query failed",
          phase: :execution,
          details:
            details(operation, reason, %{code: :postgres_query_failed, query_reason: reason_value})
        )

      {:invalid_postgres_query_result, result} ->
        Jido.Error.internal_error("PostgreSQL backend returned invalid query result",
          details:
            details(operation, reason, %{code: :invalid_postgres_query_result, result: result})
        )

      {:postgres_query_exception, exception, stacktrace} ->
        Jido.Error.internal_error("PostgreSQL backend query raised an exception",
          details:
            details(operation, reason, %{
              code: :postgres_query_exception,
              exception: inspect(exception),
              stacktrace: stacktrace
            })
        )

      :invalid_long_term_backend_operation ->
        Jido.Error.internal_error("long-term backend operation is unsupported",
          details: details(operation, reason, %{code: :invalid_long_term_backend_operation})
        )

      :not_found ->
        Jido.Error.execution_error("memory record not found",
          phase: :execution,
          details: details(operation, reason, %{code: :not_found})
        )

      {:access_denied, decision} ->
        Jido.Error.execution_error("memory access denied by policy",
          phase: :execution,
          details:
            details(operation, reason, %{
              code: :access_denied,
              policy_reason: Map.get(decision, :reason),
              policy_effect: Map.get(decision, :effect),
              matched_rule: Map.get(decision, :matched_rule)
            })
        )

      :approval_token_required ->
        Jido.Error.execution_error("approval token required for operation",
          phase: :execution,
          details: details(operation, reason, %{code: :approval_required})
        )

      :approval_token_invalid ->
        Jido.Error.execution_error("approval token is invalid",
          phase: :execution,
          details: details(operation, reason, %{code: :approval_invalid})
        )

      :approval_token_expired ->
        Jido.Error.execution_error("approval token has expired",
          phase: :execution,
          details: details(operation, reason, %{code: :approval_expired})
        )

      :approval_token_actor_mismatch ->
        Jido.Error.execution_error("approval token actor mismatch",
          phase: :execution,
          details: details(operation, reason, %{code: :approval_actor_mismatch})
        )

      :approval_token_action_not_allowed ->
        Jido.Error.execution_error("approval token does not allow this action",
          phase: :execution,
          details: details(operation, reason, %{code: :approval_action_not_allowed})
        )

      {:retention_blocked, reason_kind, value} ->
        Jido.Error.validation_error("memory persistence blocked by retention policy",
          kind: :input,
          subject: :retention,
          details:
            details(operation, reason, %{
              code: :retention_blocked,
              reason_kind: reason_kind,
              value: value
            })
        )

      {:missing_runtime_capabilities, module, missing} ->
        Jido.Error.validation_error("jido_memory runtime capabilities are missing",
          kind: :config,
          subject: module,
          details:
            details(operation, reason, %{
              code: :runtime_incompatible,
              missing_capabilities: missing
            })
        )

      {:missing_runtime_module, module, reason_value} ->
        Jido.Error.validation_error("jido_memory runtime module could not be loaded",
          kind: :config,
          subject: module,
          details:
            details(operation, reason, %{code: :runtime_incompatible, load_reason: reason_value})
        )

      {:unsupported_jido_memory_version, version, requirement} ->
        Jido.Error.validation_error("unsupported jido_memory version",
          kind: :config,
          subject: :jido_memory_version,
          details:
            details(operation, reason, %{
              code: :runtime_incompatible,
              version: version,
              requirement: requirement
            })
        )

      {:invalid_tier_transition, previous_tier, next_tier} ->
        Jido.Error.validation_error("invalid tier transition in metadata",
          kind: :input,
          subject: :tier,
          details:
            details(operation, reason, %{
              code: :invalid_lifecycle_transition,
              previous_tier: previous_tier,
              next_tier: next_tier
            })
        )

      {:invalid_mem_os_field, field, value} ->
        Jido.Error.validation_error("invalid MemoryOS metadata field",
          kind: :input,
          subject: field,
          details:
            details(operation, reason, %{code: :invalid_metadata, field: field, value: value})
        )

      {:runtime_exception, exception, stacktrace} ->
        Jido.Error.internal_error("memory runtime raised an exception",
          details:
            details(operation, reason, %{
              code: :runtime_exception,
              exception: inspect(exception),
              stacktrace: stacktrace
            })
        )

      errors when is_list(errors) ->
        if config_errors?(errors) do
          Jido.Error.validation_error("invalid MemoryOS configuration",
            kind: :config,
            subject: :config,
            details: details(operation, reason, %{code: :invalid_config, errors: errors})
          )
        else
          Jido.Error.execution_error("memory runtime returned error list",
            phase: :execution,
            details: details(operation, reason, %{code: :upstream_error_list, errors: errors})
          )
        end

      _ ->
        Jido.Error.execution_error("upstream memory runtime error",
          phase: :execution,
          details: details(operation, reason, %{code: :upstream_error})
        )
    end
  end

  @spec config_errors?([term()]) :: boolean()
  defp config_errors?(errors), do: Enum.all?(errors, &match?(%ConfigError{}, &1))

  @spec details(atom(), term(), map()) :: map()
  defp details(operation, reason, extra) do
    extra
    |> Map.put_new(:operation, operation)
    |> Map.put_new(:reason, reason)
  end
end
