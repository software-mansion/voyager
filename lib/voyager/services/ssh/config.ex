defmodule Voyager.Services.SSH.Config do
  @moduledoc false

  alias Voyager.Services.LocalFiles

  @type host :: %{
          alias: String.t(),
          host_name: String.t() | nil,
          user: String.t() | nil,
          port: :inet.port_number() | nil,
          identity_files: [Path.t()],
          identity_agent: Path.t() | :none | nil
        }

  @type unsupported :: %{keyword: String.t(), type: :keyword | :block | :value}

  @type result :: %{hosts: [host()], unsupported: [unsupported()]}

  @max_include_depth 16
  @bad_include %{keyword: "include", type: :value}
  @back_to_top_level {"host", ["*"]}

  @spec read(Path.t()) :: {:ok, result()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path \\ "~/.ssh/config") do
    with {:ok, contents} <- LocalFiles.read(path), do: {:ok, parse(contents)}
  end

  @spec parse(String.t()) :: result()
  def parse(contents) do
    {_lines, unsupported} = lines(contents, 0, [])

    %{hosts: [], unsupported: Enum.reverse(unsupported)}
  end

  defp lines(contents, depth, unsupported) do
    {lines, unsupported} =
      contents
      |> String.split("\n")
      |> Enum.flat_map_reduce(unsupported, &line/2)

    {lines, {_in_block?, unsupported}} =
      Enum.flat_map_reduce(lines, {false, unsupported}, &include(&1, &2, depth))

    {lines, unsupported}
  end

  defp include({"include", patterns}, {false, unsupported}, depth) do
    {lines, unsupported} =
      Enum.flat_map_reduce(patterns, unsupported, &include_pattern(&1, &2, depth))

    {lines ++ [@back_to_top_level], {false, unsupported}}
  end

  defp include({"include", _patterns}, {true, unsupported}, _depth),
    do: {[], {true, [%{keyword: "include", type: :block} | unsupported]}}

  defp include({keyword, _args} = line, {in_block?, unsupported}, _depth),
    do: {[line], {in_block? or keyword in ["host", "match"], unsupported}}

  defp include_pattern(pattern, unsupported, depth) do
    if depth == @max_include_depth or String.contains?(pattern, ["%", "${"]) do
      {[], [@bad_include | unsupported]}
    else
      pattern
      |> Path.expand("~/.ssh")
      |> Path.wildcard()
      |> Enum.flat_map_reduce(unsupported, &include_file(&1, &2, depth + 1))
    end
  end

  defp include_file(path, unsupported, depth) do
    case File.read(path) do
      {:ok, contents} -> lines(contents, depth, unsupported)
      {:error, _reason} -> {[], [@bad_include | unsupported]}
    end
  end

  defp line(line, unsupported) do
    case String.trim(line) do
      "" ->
        {[], unsupported}

      <<c, _::binary>> when c in [?#, ?=] ->
        {[], unsupported}

      line ->
        [keyword | rest] = String.split(line, ~r/\s*=\s*|\s+/, parts: 2)
        keyword = String.downcase(keyword)

        case args(Enum.join(rest)) do
          {:ok, [_ | _] = args} -> {[{keyword, args}], unsupported}
          _ -> {[], [%{keyword: keyword, type: :value} | unsupported]}
        end
    end
  end

  defp args(s), do: skip(s, [])

  defp skip(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: skip(rest, acc)
  defp skip("#" <> _comment, acc), do: {:ok, Enum.reverse(acc)}
  defp skip("", acc), do: {:ok, Enum.reverse(acc)}
  defp skip(s, acc), do: token(s, "", nil, acc)

  defp token(<<?\\, c, rest::binary>>, arg, q, acc)
       when c in [?', ?", ?\\] or (c == ?\s and is_nil(q)),
       do: token(rest, <<arg::binary, c>>, q, acc)

  defp token(<<c, rest::binary>>, arg, nil, acc) when c in [?\s, ?\t], do: skip(rest, [arg | acc])
  defp token(<<c, rest::binary>>, arg, nil, acc) when c in [?", ?'], do: token(rest, arg, c, acc)
  defp token(<<q, rest::binary>>, arg, q, acc), do: token(rest, arg, nil, acc)
  defp token(<<c, rest::binary>>, arg, q, acc), do: token(rest, <<arg::binary, c>>, q, acc)
  defp token("", arg, nil, acc), do: {:ok, Enum.reverse([arg | acc])}
  defp token("", _arg, _q, _acc), do: :error
end
