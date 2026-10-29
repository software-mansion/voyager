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
  @top_level {"host", ["*"]}

  @fields %{
    "hostname" => :host_name,
    "user" => :user,
    "port" => :port,
    "identityfile" => :identity_files,
    "identityagent" => :identity_agent
  }

  @default_agent ["SSH_AUTH_SOCK", "$SSH_AUTH_SOCK", "${SSH_AUTH_SOCK}"]

  @spec read(Path.t()) :: {:ok, result()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path \\ "~/.ssh/config") do
    with {:ok, contents} <- LocalFiles.read(path), do: {:ok, parse(contents)}
  end

  @spec parse(String.t()) :: result()
  def parse(contents) do
    {lines, unsupported} = lines(contents, 0, [])
    {settings, unsupported} = Enum.flat_map_reduce([@top_level | lines], unsupported, &setting/2)
    blocks = blocks(settings)

    %{
      hosts: blocks |> aliases() |> Enum.map(&host(&1, blocks)),
      unsupported: unsupported |> Enum.reverse() |> Enum.uniq()
    }
  end

  defp setting({"host", _patterns} = line, unsupported), do: {[line], unsupported}

  defp setting({"match", _criteria} = line, unsupported),
    do: {[line], [%{keyword: "match", type: :block} | unsupported]}

  defp setting({keyword, [arg | _rest]}, unsupported) do
    case value(keyword, arg) do
      {:ok, setting} -> {[setting], unsupported}
      :error -> {[], [%{keyword: keyword, type: :value} | unsupported]}
      :unsupported -> {[], [%{keyword: keyword, type: :keyword} | unsupported]}
    end
  end

  defp value("identityagent", "none"), do: {:ok, {:identity_agent, :none}}

  defp value("identityagent", agent) when agent in @default_agent,
    do: {:ok, {:identity_agent, nil}}

  defp value(keyword, arg) when is_map_key(@fields, keyword) do
    if String.contains?(arg, ["%", "$"]), do: :error, else: field(@fields[keyword], arg)
  end

  defp value(_keyword, _arg), do: :unsupported

  defp field(:port, arg) do
    case Integer.parse(arg) do
      {port, ""} when port in 1..65_535 -> {:ok, {:port, port}}
      _ -> :error
    end
  end

  defp field(name, path) when name in [:identity_files, :identity_agent],
    do: {:ok, {name, Path.expand(path)}}

  defp field(name, arg), do: {:ok, {name, arg}}

  defp blocks(settings) do
    settings
    |> Enum.reduce([], &block/2)
    |> Enum.map(&%{&1 | settings: Enum.reverse(&1.settings)})
    |> Enum.reverse()
  end

  defp block({"host", patterns}, blocks), do: [%{patterns: patterns, settings: []} | blocks]
  defp block({"match", _criteria}, blocks), do: [%{patterns: [], settings: []} | blocks]

  defp block(setting, [block | blocks]),
    do: [%{block | settings: [setting | block.settings]} | blocks]

  defp aliases(blocks) do
    blocks
    |> Enum.flat_map(& &1.patterns)
    |> Enum.reject(&String.contains?(&1, ["*", "?", "!"]))
    |> Enum.uniq()
  end

  defp host(name, blocks) do
    resolved =
      blocks
      |> Enum.filter(&applies?(&1.patterns, name))
      |> Enum.flat_map(& &1.settings)
      |> Enum.reduce(%{alias: name}, &resolve/2)

    Map.merge(
      %{host_name: nil, user: nil, port: nil, identity_files: [], identity_agent: nil},
      resolved
    )
  end

  defp applies?(patterns, name) do
    Enum.any?(patterns, &glob_match?(&1, name)) and
      not Enum.any?(patterns, fn
        "!" <> pattern -> glob_match?(pattern, name)
        _pattern -> false
      end)
  end

  defp glob_match?(pattern, name) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/\A#{regex}\z/, name)
  end

  defp resolve({:identity_files, path}, host),
    do: Map.update(host, :identity_files, [path], &Enum.uniq(&1 ++ [path]))

  defp resolve({field, value}, host), do: Map.put_new(host, field, value)

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

    {lines ++ [@top_level], {false, unsupported}}
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
          _ -> {broken_block(keyword), [%{keyword: keyword, type: :value} | unsupported]}
        end
    end
  end

  defp broken_block(keyword) when keyword in ["host", "match"], do: [{"host", []}]
  defp broken_block(_keyword), do: []

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
