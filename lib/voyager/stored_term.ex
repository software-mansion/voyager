defmodule Voyager.StoredTerm do
  @moduledoc "Ecto type storing any term with `:erlang.term_to_binary/2`, so it loads back unchanged."

  use Ecto.Type

  # zlib costs ~4x on small terms and saves nothing there; it pays off on large args and values.
  @compress_over_bytes 256

  @impl true
  def type, do: :binary

  @impl true
  def cast(term), do: {:ok, term}

  @impl true
  def dump(term), do: {:ok, encode(term)}

  @impl true
  def load(binary) when is_binary(binary), do: {:ok, decode(binary)}

  @spec encode(term()) :: binary()
  def encode(term) do
    if :erlang.external_size(term) > @compress_over_bytes,
      do: :erlang.term_to_binary(term, [:compressed]),
      else: :erlang.term_to_binary(term)
  end

  # Not `[:safe]`: traced terms carry the remote node's atoms, which after a restart don't exist yet.
  @spec decode(binary()) :: term()
  def decode(binary), do: :erlang.binary_to_term(binary)
end
