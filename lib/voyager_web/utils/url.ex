defmodule VoyagerWeb.Utils.URL do
  @moduledoc """
  Helpers for reading and rewriting URLs and their query params.

  Query-param helpers preserve every other part of the URL (path and the
  remaining params), so callers can update a single param without needing to
  know about the others.
  """

  @doc """
  Strips scheme/host from an absolute URL, keeping only the path and query.

      iex> VoyagerWeb.Utils.URL.to_relative("http://example.com/foo?bar=baz")
      "/foo?bar=baz"
  """
  @spec to_relative(String.t()) :: String.t()
  def to_relative(url) when is_binary(url) do
    %URI{path: path, query: query} = URI.parse(url)
    URI.to_string(%URI{path: path, query: query})
  end

  @doc """
  Returns the value of a query param, or `nil` when it is absent.
  """
  @spec get_query_param(String.t(), String.t()) :: String.t() | nil
  def get_query_param(url, key) when is_binary(url) and is_binary(key) do
    (URI.parse(url).query || "")
    |> URI.decode_query()
    |> Map.get(key)
  end

  @doc """
  Inserts or updates a single query param, preserving all others.
  """
  @spec put_query_param(String.t(), String.t(), String.t()) :: String.t()
  def put_query_param(url, key, value)
      when is_binary(url) and is_binary(key) and is_binary(value) do
    put_query_params(url, %{key => value})
  end

  @doc """
  Inserts or updates several query params at once, preserving all others.
  """
  @spec put_query_params(String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def put_query_params(url, params) when is_binary(url) and is_map(params) do
    modify_query_params(url, &Map.merge(&1, params))
  end

  @doc """
  Removes a query param, preserving all others.
  """
  @spec drop_query_param(String.t(), String.t()) :: String.t()
  def drop_query_param(url, key) when is_binary(url) and is_binary(key) do
    modify_query_params(url, &Map.delete(&1, key))
  end

  @doc """
  Rewrites the query string by applying `fun` to the decoded param map. An empty
  result drops the query string entirely.
  """
  @spec modify_query_params(String.t(), (map() -> map())) :: String.t()
  def modify_query_params(url, fun) when is_binary(url) and is_function(fun, 1) do
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> fun.()
      |> case do
        params when map_size(params) == 0 -> nil
        params -> URI.encode_query(params)
      end

    URI.to_string(%URI{uri | query: query})
  end
end
