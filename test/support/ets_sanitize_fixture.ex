defmodule Voyager.Test.EtsSanitizeFixture do
  @moduledoc """
  Shared `{input, expected}` terms for `Voyager.Services.Ets.Sanitize` and the
  VOY-230 Erlang truncator. Expected values are written out, not computed.
  """

  alias Voyager.Services.Ets.Sanitize

  @marker Sanitize.marker()
  @binary_limit Sanitize.max_binary_bytes()
  @collection_limit Sanitize.max_collection()

  @doc """
  Sample terms covering binary overflow, collection overflow, depth, nested
  mix, already-truncated leaves, non-binary bitstrings, and keys that must
  not be redacted.
  """
  @spec samples() :: [{term(), term()}]
  def samples do
    [
      binary_overflow(),
      collection_overflow_list(),
      collection_overflow_map(),
      collection_overflow_tuple(),
      depth_cap(),
      nested_mix(),
      already_truncated_leaf(),
      no_redaction(),
      bitstring_under_cap(),
      bitstring_overflow()
    ]
  end

  defp binary_overflow do
    input = :binary.copy(<<"a">>, 600)
    prefix = :binary.copy(<<"a">>, @binary_limit)
    expected = {@marker, :binary, prefix, 600}
    {input, expected}
  end

  defp collection_overflow_list do
    input = Enum.to_list(1..60)
    expected = {@marker, :list, Enum.to_list(1..@collection_limit), 10}
    {input, expected}
  end

  defp collection_overflow_map do
    input = Map.new(1..60, &{&1, &1})
    taken = Map.new(1..@collection_limit, &{&1, &1})
    expected = {@marker, :map, taken, 10}
    {input, expected}
  end

  defp collection_overflow_tuple do
    input = List.to_tuple(Enum.to_list(1..60))
    expected = {@marker, :tuple, Enum.to_list(1..@collection_limit), 10}
    {input, expected}
  end

  defp depth_cap do
    input = [[[[[[:x]]]]]]
    expected = [[[[[{@marker, :depth}]]]]]
    {input, expected}
  end

  defp nested_mix do
    blob = :binary.copy(<<"x">>, 600)

    input =
      {:rec,
       %{
         blob: blob,
         items: Enum.to_list(1..60),
         password: "secret"
       }}

    expected =
      {:rec,
       %{
         blob: {@marker, :binary, :binary.copy(<<"x">>, @binary_limit), 600},
         items: {@marker, :list, Enum.to_list(1..@collection_limit), 10},
         password: "secret"
       }}

    {input, expected}
  end

  defp already_truncated_leaf do
    input = {@marker, :binary, <<"abc">>, 1000}
    {input, input}
  end

  defp no_redaction do
    input = %{password: "hunter2", token: "abc", api_key: "k"}
    {input, input}
  end

  defp bitstring_under_cap do
    input = <<1::4>>
    expected = {@marker, :binary, <<1::4, 0::4>>, 1}
    {input, expected}
  end

  defp bitstring_overflow do
    input = <<0::size(600 * 8 + 1)>>
    padded = <<input::bitstring, 0::size(7)>>
    prefix = binary_part(padded, 0, @binary_limit)
    expected = {@marker, :binary, prefix, 601}
    {input, expected}
  end
end
