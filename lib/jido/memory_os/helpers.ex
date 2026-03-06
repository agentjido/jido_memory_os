defmodule Jido.MemoryOS.Helpers do
  @moduledoc """
  Shared normalization and utility functions used across MemoryOS modules.

  These helpers handle indifferent atom/string key access, type coercion,
  and common map operations needed by the plugin, framework adapter, and
  action support layers.
  """

  @doc """
  Normalizes map-like inputs (maps, keyword lists) into maps.
  """
  @spec normalize_map(term()) :: map()
  def normalize_map(%{} = map), do: map

  def normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Map.new(list), else: %{}
  end

  def normalize_map(_value), do: %{}

  @doc """
  Reads a value from a map, checking both atom and string keys.
  """
  @spec map_get(map(), atom() | String.t(), term()) :: term()
  def map_get(map, key, default \\ nil)

  def map_get(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def map_get(map, key, default) when is_binary(key) do
    case Enum.find(map, fn
           {atom_key, _value} when is_atom(atom_key) -> Atom.to_string(atom_key) == key
           _ -> false
         end) do
      {_, value} -> value
      nil -> Map.get(map, key, default)
    end
  end

  @doc """
  Normalizes keyword-like inputs into keyword lists.
  """
  @spec normalize_keyword(term()) :: keyword()
  def normalize_keyword(opts) when is_list(opts), do: opts
  def normalize_keyword(%{} = opts), do: Enum.to_list(opts)
  def normalize_keyword(_opts), do: []

  @doc """
  Normalizes any tag-like payload to a unique list of strings.
  """
  @spec normalize_tags(term()) :: [String.t()]
  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      tag when is_binary(tag) -> String.trim(tag)
      tag when is_atom(tag) -> tag |> Atom.to_string() |> String.trim()
      tag -> tag |> to_string() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_tags(tag) when is_binary(tag), do: normalize_tags([tag])
  def normalize_tags(tag) when is_atom(tag), do: normalize_tags([tag])
  def normalize_tags(_tags), do: []

  @doc """
  Puts a key/value into a map only if the value is not nil.
  """
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Returns a trimmed non-empty string, or the fallback if blank/nil.
  """
  @spec normalize_non_empty_string(term(), String.t() | nil) :: String.t() | nil
  def normalize_non_empty_string(value, fallback)

  def normalize_non_empty_string(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: fallback, else: trimmed
  end

  def normalize_non_empty_string(nil, fallback), do: fallback

  def normalize_non_empty_string(value, fallback),
    do: normalize_non_empty_string(to_string(value), fallback)

  @doc """
  Returns true if the term is a Jido.Error.* struct.
  """
  @spec jido_error?(term()) :: boolean()
  def jido_error?(%{__struct__: module}) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Jido.Error.")
  end

  def jido_error?(_reason), do: false

  @doc """
  Extracts the first non-empty text from a list of candidate field names,
  checking both atom and string keys in the given map.
  """
  @spec find_text_in(map(), [atom()]) :: String.t() | nil
  def find_text_in(map, field_names) do
    Enum.find_value(field_names, fn field ->
      case map_get(map, field) do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end
    end)
  end
end
