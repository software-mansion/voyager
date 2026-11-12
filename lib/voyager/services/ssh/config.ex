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
  @every_host_header {:header, ["*"]}
  @no_host_header {:header, []}

  @field_by_keyword %{
    "hostname" => :host_name,
    "user" => :user,
    "port" => :port,
    "identityfile" => :identity_files,
    "identityagent" => :identity_agent
  }

  @env_agent_values ["SSH_AUTH_SOCK", "$SSH_AUTH_SOCK", "${SSH_AUTH_SOCK}"]

  @spec read(Path.t()) ::
          {:ok, result()}
          | {:error, {:read_failed, {Path.t(), LocalFiles.read_error()}}}
  def read(path \\ "~/.ssh/config") do
    with {:ok, contents} <- LocalFiles.read_config(path), do: {:ok, parse(contents)}
  end

  @spec parse(String.t()) :: result()
  def parse(contents) do
    items =
      contents
      |> parse_contents(0)
      |> apply_top_level_to_every_host()
      |> Enum.map(&to_setting/1)

    %{
      hosts: items |> aliases() |> Enum.map(&resolve_host(&1, items)),
      unsupported: unsupported(items)
    }
  end

  defp apply_top_level_to_every_host(items), do: [@every_host_header | items]

  defp parse_contents(contents, depth) do
    {top_level, blocks} =
      contents
      |> String.replace_invalid()
      |> String.split("\n")
      |> Enum.flat_map(&parse_line/1)
      |> Enum.split_while(&(not match?({:header, _patterns}, &1)))

    Enum.flat_map(top_level, &expand_include(&1, depth)) ++ Enum.map(blocks, &reject_include/1)
  end

  defp parse_line(line) do
    case String.trim(line) do
      "" -> []
      <<c, _::binary>> when c in [?#, ?=] -> []
      trimmed -> parse_keyword_line(trimmed)
    end
  end

  defp parse_keyword_line(line) do
    case String.split(line, ~r/\s*=\s*|\s+/, parts: 2) do
      [keyword] -> bad_value(String.downcase(keyword))
      [keyword, raw_args] -> parse_args(String.downcase(keyword), raw_args)
    end
  end

  defp parse_args(keyword, raw_args) do
    with {:ok, [_ | _] = args} <- split_args(raw_args, []),
         false <- "" in args do
      line_items(keyword, args)
    else
      _no_args -> bad_value(keyword)
    end
  end

  defp line_items("host", patterns), do: [{:header, patterns}]
  defp line_items("match", _criteria), do: [@no_host_header, {:problem, "match", :block}]
  defp line_items(keyword, args), do: [{:directive, keyword, args}]

  defp bad_value(keyword) when keyword in ["host", "match"],
    do: [@no_host_header, {:problem, keyword, :value}]

  defp bad_value(keyword), do: [{:problem, keyword, :value}]

  defp expand_include({:directive, "include", patterns}, depth),
    do: Enum.flat_map(patterns, &include_pattern(&1, depth)) ++ [@every_host_header]

  defp expand_include(item, _depth), do: [item]

  defp reject_include({:directive, "include", _patterns}), do: {:problem, "include", :block}
  defp reject_include(item), do: item

  defp include_pattern(pattern, depth) do
    if depth == @max_include_depth or String.contains?(pattern, ["%", "{", "**", <<0>>]) do
      [@bad_include]
    else
      pattern
      |> Path.expand("~/.ssh")
      |> Path.wildcard()
      |> Enum.flat_map(&include_file(&1, depth + 1))
    end
  end

  defp include_file(path, depth) do
    case LocalFiles.read_config(path) do
      {:ok, contents} -> [@every_host_header | parse_contents(contents, depth)]
      {:error, _reason} -> [@bad_include]
    end
  end

  defp to_setting({:directive, "identityfile", ["none"]}), do: {:problem, "identityfile", :value}

  defp to_setting({:directive, "identityagent", ["none"]}),
    do: {:setting, :identity_agent, :none}

  defp to_setting({:directive, "identityagent", [agent]})
       when agent in @env_agent_values,
       do: {:setting, :identity_agent, nil}

  defp to_setting({:directive, keyword, [arg]})
       when is_map_key(@field_by_keyword, keyword) do
    if String.contains?(arg, ["%", "$"]) do
      {:problem, keyword, :value}
    else
      parse_field(keyword, arg)
    end
  end

  defp to_setting({:directive, keyword, _args})
       when is_map_key(@field_by_keyword, keyword),
       do: {:problem, keyword, :value}

  defp to_setting({:directive, keyword, _args}), do: {:problem, keyword, :keyword}
  defp to_setting(item), do: item

  defp parse_field("port", arg) do
    case Integer.parse(arg) do
      {port, ""} when port in 1..65_535 -> {:setting, :port, port}
      _ -> {:problem, "port", :value}
    end
  end

  defp parse_field(keyword, path) when keyword in ["identityfile", "identityagent"],
    do: {:setting, @field_by_keyword[keyword], Path.expand(path)}

  defp parse_field(keyword, arg), do: {:setting, @field_by_keyword[keyword], arg}

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

  defp resolve_host(host_alias, items) do
    resolved =
      items
      |> settings_for(host_alias)
      |> Enum.reduce(%{alias: host_alias}, &merge_setting/2)

    Map.merge(
      %{host_name: nil, user: nil, port: nil, identity_files: [], identity_agent: nil},
      resolved
    )
  end

  defp settings_for(items, host_alias) do
    {settings, _active?} =
      Enum.flat_map_reduce(items, false, fn
        {:header, patterns}, _active? -> {[], applies?(patterns, host_alias)}
        {:setting, _field, _value} = setting, true -> {[setting], true}
        _item, active? -> {[], active?}
      end)

    settings
  end

  defp merge_setting({:setting, :identity_files, path}, host),
    do: Map.update(host, :identity_files, [path], &Enum.uniq(&1 ++ [path]))

  defp merge_setting({:setting, field, value}, host), do: Map.put_new(host, field, value)

  defp applies?(patterns, host_alias) do
    Enum.any?(patterns, &glob_match?(&1, host_alias)) and
      not Enum.any?(patterns, fn
        "!" <> pattern -> glob_match?(pattern, host_alias)
        _pattern -> false
      end)
  end

  defp glob_match?(pattern, host_alias) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/\A#{regex}\z/, host_alias)
  end

  defp split_args(<<c, rest::binary>>, args) when c in [?\s, ?\t], do: split_args(rest, args)
  defp split_args("#" <> _comment, args), do: {:ok, Enum.reverse(args)}
  defp split_args("", args), do: {:ok, Enum.reverse(args)}
  defp split_args(rest, args), do: read_unquoted(rest, "", args)

  defp read_unquoted(<<?\\, c, rest::binary>>, arg, args) when c in [?', ?", ?\\, ?\s],
    do: read_unquoted(rest, <<arg::binary, c>>, args)

  defp read_unquoted(<<c, rest::binary>>, arg, args) when c in [?\s, ?\t],
    do: split_args(rest, [arg | args])

  defp read_unquoted(<<c, rest::binary>>, arg, args) when c in [?", ?'],
    do: read_quoted(rest, arg, c, args)

  defp read_unquoted(<<c, rest::binary>>, arg, args),
    do: read_unquoted(rest, <<arg::binary, c>>, args)

  defp read_unquoted("", arg, args), do: {:ok, Enum.reverse([arg | args])}

  defp read_quoted(<<?\\, c, rest::binary>>, arg, quote_char, args) when c in [?', ?", ?\\],
    do: read_quoted(rest, <<arg::binary, c>>, quote_char, args)

  defp read_quoted(<<c, rest::binary>>, arg, quote_char, args) when c == quote_char,
    do: read_unquoted(rest, arg, args)

  defp read_quoted(<<c, rest::binary>>, arg, quote_char, args),
    do: read_quoted(rest, <<arg::binary, c>>, quote_char, args)

  defp read_quoted("", _arg, _quote_char, _args), do: :error
end
