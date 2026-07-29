defmodule Anubis.Protocol.Schema do
  @moduledoc """
  Helpers for building JSON-RPC message schemas inside protocol version modules.

  A protocol version owns the full shape of its messages: method names, params
  schemas, and the JSON-RPC envelope around them. These helpers build the
  envelope branches for `{:multi, :method, branches}` schemas and merge the
  generic `params._meta.progressToken` slot, so version modules stay focused
  on what changed between versions.
  """

  @progress_meta %{"_meta" => %{"progressToken" => {:either, {:string, :integer}}}}

  @doc """
  Returns the schema fragment for the `params._meta.progressToken` slot
  shared by all MCP requests.
  """
  @spec progress_meta() :: map()
  def progress_meta, do: @progress_meta

  @doc """
  Merges the progress `_meta` slot into a params schema map.

  Non-map schemas (e.g. `:map`) pass through unchanged.
  """
  @spec with_progress_meta(term()) :: term()
  def with_progress_meta(schema) when is_map(schema), do: Map.merge(schema, @progress_meta)
  def with_progress_meta(schema), do: schema

  @doc """
  Builds a JSON-RPC request branch for a `{:multi, :method, branches}` schema.
  """
  @spec request_branch(String.t(), term()) :: map()
  def request_branch(method, params_schema) do
    %{
      "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
      "method" => {:required, {:literal, method}},
      "params" => params_schema,
      "id" => {:required, {:either, {:string, :integer}}}
    }
  end

  @doc """
  Builds a JSON-RPC notification branch for a `{:multi, :method, branches}` schema.
  """
  @spec notification_branch(String.t(), term()) :: map()
  def notification_branch(method, params_schema) do
    %{
      "jsonrpc" => {:required, {:string, {:eq, "2.0"}}},
      "method" => {:required, {:literal, method}},
      "params" => params_schema
    }
  end
end
