defmodule Voyager.Services.McpConfigFile do
  @moduledoc """
  Reads the MCP servers a coding agent's config file defines and adds Voyager's entry to it.

  JSON keeps the user's key order but cannot keep comments, so a file that only parses as
  JSONC is reported as unreadable and never written. TOML is edited as text, keeping comments.
  """

  alias Jason.OrderedObject

  @server_name "voyager"

  @type format :: :json | :toml
  @type servers :: %{String.t() => map()}

  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc """
  Returns every server under `key` in `path`, each entry as a flat map. A missing file has no
  servers. Fails when the file cannot be read or parsed, or `key` does not hold an object.
  """
  @spec servers(Path.t(), format(), [String.t()]) :: {:ok, servers()} | {:error, term()}
  def servers(path, :json, key) do
    with {:ok, doc} <- read_json(path),
         {:ok, servers} <- fetch_object(doc, key) do
      {:ok, Map.new(servers.values, fn {name, entry} -> {name, flat_entry(entry)} end)}
    end
  end

  def servers(path, :toml, [table]) do
    with {:ok, text} <- read(path), do: {:ok, toml_servers(text, table)}
  end

  @doc "Adds or replaces the `voyager` server under `key` in `path`, creating the file if needed."
  @spec put_server(Path.t(), format(), [String.t()], map()) :: :ok | {:error, term()}
  def put_server(path, :json, key, entry) do
    with {:ok, doc} <- read_json(path),
         {:ok, _servers} <- fetch_object(doc, key) do
      write_json(path, put_path(doc, key ++ [@server_name], entry))
    end
  end

  def put_server(path, :toml, [table], entry) do
    with {:ok, text} <- read(path) do
      kept =
        text
        |> remove_toml_table("#{table}.#{@server_name}", false)
        |> String.trim_trailing()

      separator = if kept == "", do: "", else: "\n\n"
      write(path, kept <> separator <> toml_table("#{table}.#{@server_name}", entry))
    end
  end

  @doc "Removes the `voyager` server under `key` from `path`, leaving the file untouched when it has none."
  @spec delete_server(Path.t(), format(), [String.t()]) :: :ok | {:error, term()}
  def delete_server(path, :json, key) do
    with {:ok, doc} <- read_json(path),
         {:ok, servers} <- fetch_object(doc, key) do
      case OrderedObject.pop(servers, @server_name) do
        {nil, _servers} -> :ok
        {_entry, servers} -> write_json(path, put_path(doc, key, servers))
      end
    end
  end

  def delete_server(path, :toml, [table]) do
    with {:ok, text} <- read(path) do
      case remove_toml_table(text, "#{table}.#{@server_name}", true) do
        ^text -> :ok
        kept -> write(path, String.trim_trailing(kept) <> "\n")
      end
    end
  end

  @spec toml_table(String.t(), map()) :: String.t()
  def toml_table(name, entry) do
    lines = Enum.map(entry, fn {key, value} -> "#{key} = #{toml_value(value)}" end)
    Enum.join(["[#{name}]" | lines], "\n") <> "\n"
  end

  defp toml_value(value) when is_binary(value), do: ~s("#{value}")
  defp toml_value(value), do: to_string(value)

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, ""}
      other -> other
    end
  end

  defp read_json(path) do
    with {:ok, text} <- read(path) do
      if String.trim(text) == "", do: {:ok, OrderedObject.new([])}, else: decode_json(text)
    end
  end

  defp decode_json(text) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, %OrderedObject{} = doc} -> {:ok, doc}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp fetch_object(object, []), do: {:ok, object}

  defp fetch_object(object, [key | rest]) do
    case OrderedObject.fetch(object, key) do
      {:ok, %OrderedObject{} = child} -> fetch_object(child, rest)
      {:ok, _other} -> {:error, :unexpected_shape}
      :error -> {:ok, OrderedObject.new([])}
    end
  end

  defp flat_entry(%OrderedObject{values: values}), do: Map.new(values)
  defp flat_entry(_entry), do: %{}

  defp put_path(%OrderedObject{values: values} = object, [key], value) do
    %{object | values: List.keystore(values, key, 0, {key, value})}
  end

  defp put_path(object, [key | rest], value) do
    child =
      case OrderedObject.fetch(object, key) do
        {:ok, %OrderedObject{} = child} -> child
        :error -> OrderedObject.new([])
      end

    put_path(object, [key], put_path(child, rest, value))
  end

  @header ~r/^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$/
  @url ~r/^\s*url\s*=\s*"([^"]*)"/

  # shortcut: only `[table.name]` headers with a `url = "…"` line are read; inline tables are not.
  defp toml_servers(text, table) do
    {servers, _current} =
      text
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {servers, current} ->
        case Regex.run(@header, line) do
          [_, header | _] -> enter_toml_table(servers, header, table)
          nil -> {put_toml_url(servers, current, line), current}
        end
      end)

    servers
  end

  defp enter_toml_table(servers, header, table) do
    case String.split(header, ".", parts: 2) do
      [^table, name] -> enter_named_table(servers, String.trim(name, "\""))
      _other -> {servers, nil}
    end
  end

  defp enter_named_table(servers, name) do
    if String.contains?(name, "."),
      do: {servers, nil},
      else: {Map.put_new(servers, name, %{}), name}
  end

  defp put_toml_url(servers, nil, _line), do: servers

  defp put_toml_url(servers, current, line) do
    case Regex.run(@url, line) do
      [_, url] -> Map.put(servers, current, %{"url" => url})
      nil -> servers
    end
  end

  defp remove_toml_table(text, name, with_subtables?) do
    [table, server] = String.split(name, ".", parts: 2)
    names = [name, ~s(#{table}."#{server}")]

    {lines, _skipping?} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {kept, skipping?} ->
        skip? =
          case Regex.run(@header, line) do
            [_, header | _] -> header in names or (with_subtables? and subtable?(header, names))
            nil -> skipping?
          end

        if skip?, do: {kept, true}, else: {[line | kept], false}
      end)

    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp subtable?(header, names), do: Enum.any?(names, &String.starts_with?(header, &1 <> "."))

  defp write_json(path, doc), do: write(path, Jason.encode!(doc, pretty: true) <> "\n")

  defp write(path, contents) do
    path = resolve_symlink(path)
    tmp = path <> ".voyager.tmp"

    File.rm(tmp)

    # Owner-only before any contents land, so a 0600 config never sits in a umask-wide temp file.
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, "", [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, contents),
         :ok <- copy_mode(path, tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # Renaming over a symlink would replace a dotfiles-managed config with a plain file.
  defp resolve_symlink(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> resolve_symlink(Path.expand(to_string(target), Path.dirname(path)))
      {:error, _reason} -> path
    end
  end

  defp copy_mode(from, to) do
    case File.stat(from) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(to, Bitwise.band(mode, 0o7777))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
