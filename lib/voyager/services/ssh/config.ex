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
  @bad_include {:problem, "include", :value}
  @all_hosts {:header, ["*"]}
  @no_hosts {:header, []}

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
    items = Enum.map([@all_hosts | parse_file(contents, 0)], &classify/1)

    %{
      hosts: items |> aliases() |> Enum.map(&host(&1, items)),
      unsupported: unsupported(items)
    }
  end

  defp parse_file(contents, depth) do
    {top_level, blocks} =
      contents
      |> String.split("\n")
      |> Enum.flat_map(&parse_line/1)
      |> Enum.split_while(&(not match?({:header, _patterns}, &1)))

    Enum.flat_map(top_level, &expand_include(&1, depth)) ++ Enum.map(blocks, &reject_include/1)
  end

  defp parse_line(line) do
    case String.trim(line) do
      "" ->
        []

      <<c, _::binary>> when c in [?#, ?=] ->
        []

      trimmed ->
        [keyword | rest] = String.split(trimmed, ~r/\s*=\s*|\s+/, parts: 2)
        keyword = String.downcase(keyword)

        case split_args(Enum.join(rest), []) do
          {:ok, [_ | _] = args} -> directive(keyword, args)
          {:ok, []} -> bad_value(keyword)
          :error -> bad_value(keyword)
        end
    end
  end

  defp directive("host", patterns), do: [{:header, patterns}]
  defp directive("match", _criteria), do: [@no_hosts, {:problem, "match", :block}]
  defp directive(keyword, args), do: [{:directive, keyword, args}]

  defp bad_value(keyword) when keyword in ["host", "match"],
    do: [@no_hosts, {:problem, keyword, :value}]

  defp bad_value(keyword), do: [{:problem, keyword, :value}]

  defp split_args(<<c, rest::binary>>, args) when c in [?\s, ?\t], do: split_args(rest, args)
  defp split_args("#" <> _comment, args), do: {:ok, Enum.reverse(args)}
  defp split_args("", args), do: {:ok, Enum.reverse(args)}
  defp split_args(rest, args), do: read_arg(rest, "", nil, args)

  defp read_arg(<<?\\, c, rest::binary>>, arg, quote_char, args)
       when c in [?', ?", ?\\] or (c == ?\s and is_nil(quote_char)),
       do: read_arg(rest, <<arg::binary, c>>, quote_char, args)

  defp read_arg(<<c, rest::binary>>, arg, nil, args) when c in [?\s, ?\t],
    do: split_args(rest, [arg | args])

  defp read_arg(<<c, rest::binary>>, arg, nil, args) when c in [?", ?'],
    do: read_arg(rest, arg, c, args)

  defp read_arg(<<quote_char, rest::binary>>, arg, quote_char, args),
    do: read_arg(rest, arg, nil, args)

  defp read_arg(<<c, rest::binary>>, arg, quote_char, args),
    do: read_arg(rest, <<arg::binary, c>>, quote_char, args)

  defp read_arg("", arg, nil, args), do: {:ok, Enum.reverse([arg | args])}
  defp read_arg("", _arg, _quote_char, _args), do: :error

  defp expand_include({:directive, "include", patterns}, depth),
    do: Enum.flat_map(patterns, &include_pattern(&1, depth)) ++ [@all_hosts]

  defp expand_include(item, _depth), do: [item]

  defp reject_include({:directive, "include", _patterns}), do: {:problem, "include", :block}
  defp reject_include(item), do: item

  defp include_pattern(pattern, depth) do
    if depth == @max_include_depth or String.contains?(pattern, ["%", "${"]) do
      [@bad_include]
    else
      pattern
      |> Path.expand("~/.ssh")
      |> Path.wildcard()
      |> Enum.flat_map(&include_file(&1, depth + 1))
    end
  end

  defp include_file(path, depth) do
    case File.read(path) do
      {:ok, contents} -> parse_file(contents, depth)
      {:error, _reason} -> [@bad_include]
    end
  end

  defp classify({:directive, keyword, [arg | _rest]}), do: parse_value(keyword, arg)
  defp classify(item), do: item

  defp parse_value("identityagent", "none"), do: {:setting, :identity_agent, :none}

  defp parse_value("identityagent", agent) when agent in @default_agent,
    do: {:setting, :identity_agent, nil}

  defp parse_value(keyword, arg) when is_map_key(@fields, keyword) do
    if String.contains?(arg, ["%", "$"]),
      do: {:problem, keyword, :value},
      else: parse_field(@fields[keyword], arg)
  end

  defp parse_value(keyword, _arg), do: {:problem, keyword, :keyword}

  defp parse_field(:port, arg) do
    case Integer.parse(arg) do
      {port, ""} when port in 1..65_535 -> {:setting, :port, port}
      _ -> {:problem, "port", :value}
    end
  end

  defp parse_field(name, path) when name in [:identity_files, :identity_agent],
    do: {:setting, name, Path.expand(path)}

  defp parse_field(name, arg), do: {:setting, name, arg}

  defp unsupported(items) do
    for {:problem, keyword, type} <- items, uniq: true, do: %{keyword: keyword, type: type}
  end

  defp aliases(items) do
    for {:header, patterns} <- items,
        pattern <- patterns,
        not String.contains?(pattern, ["*", "?", "!"]),
        uniq: true,
        do: pattern
  end

  defp host(name, items) do
    {_active?, resolved} = Enum.reduce(items, {false, %{alias: name}}, &apply_item(&1, &2, name))

    Map.merge(
      %{host_name: nil, user: nil, port: nil, identity_files: [], identity_agent: nil},
      resolved
    )
  end

  defp apply_item({:header, patterns}, {_active?, host}, name),
    do: {applies?(patterns, name), host}

  defp apply_item({:setting, :identity_files, path}, {true, host}, _name),
    do: {true, Map.update(host, :identity_files, [path], &Enum.uniq(&1 ++ [path]))}

  defp apply_item({:setting, field, value}, {true, host}, _name),
    do: {true, Map.put_new(host, field, value)}

  defp apply_item(_item, state, _name), do: state

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
end
