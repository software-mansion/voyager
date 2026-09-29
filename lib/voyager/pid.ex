defmodule Voyager.Pid do
  @moduledoc """
  Converts PIDs to and from their `"<X.Y.Z>"` string representation and
  formats them for display. The display format and the connected node's id
  are cached in `:persistent_term`, so formatting never makes a call.
  """

  alias Voyager.Settings

  @format_key {__MODULE__, :format}
  @node_id_key {__MODULE__, :node_id}
  @formats [:distribution, :local]

  @spec display(pid()) :: String.t()
  def display(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @spec parse(String.t()) :: pid() | nil
  def parse(pid_str) when is_binary(pid_str) do
    pid_str |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  @doc """
  The `N` of `node`'s pids as this node prints them, `<N.X.Y>`. It depends on
  the node name alone, so it is read off a pid built from the name.
  """
  @spec node_id(node()) :: String.t()
  def node_id(node) do
    name = Atom.to_string(node)

    <<131, 88, 118, byte_size(name)::16, name::binary, 0::32, 0::32, 0::32>>
    |> :erlang.binary_to_term()
    |> display()
    |> String.trim_leading("<")
    |> String.split(".")
    |> hd()
  end

  @doc "The connected node's `node_id/1`, cached by `put_node/1`."
  @spec cached_node_id() :: String.t() | nil
  def cached_node_id, do: :persistent_term.get(@node_id_key, nil)

  @doc "Caches the `node_id/1` of the connected `node`; `nil` clears it."
  @spec put_node(node() | nil) :: :ok
  def put_node(nil), do: :persistent_term.put(@node_id_key, nil)
  def put_node(node), do: :persistent_term.put(@node_id_key, node_id(node))

  @doc """
  The display format cached by `load_format/0` or `put_format/1`;
  `:distribution` until either runs.
  """
  @spec cached_format() :: :distribution | :local
  def cached_format, do: :persistent_term.get(@format_key, :distribution)

  @doc """
  Reads the PID format setting into the cache. Unknown values fall back to
  `:distribution`.
  """
  @spec load_format() :: :ok
  def load_format do
    :pid_format
    |> Settings.get(:distribution)
    |> normalize_format()
    |> put_format()
  end

  @spec put_format(:distribution | :local) :: :ok
  def put_format(format) when format in @formats do
    :persistent_term.put(@format_key, format)
  end

  @doc """
  Formats a PID for display. Omitting the format uses `cached_format/0`; an
  unknown format falls back to `:distribution`. `:local` shortens only the
  connected node's pids, or any pid while no node is connected.

      iex> Voyager.Pid.format("<123.23.423>", :distribution)
      "<123.23.423>"
      iex> Voyager.Pid.format("<123.23.423>", :local)
      "<0.23.423>"
  """
  @spec format(pid() | String.t(), atom()) :: String.t()
  def format(pid, format \\ cached_format())

  def format(pid, format) when format in @formats do
    pid
    |> pid_to_string()
    |> maybe_localize(format)
  end

  def format(pid, _format), do: format(pid, :distribution)

  @doc "An `:inspect_fun` that renders every pid, however deeply nested, via `format/1`."
  @spec inspect_fun(term(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect_fun(pid, _opts) when is_pid(pid), do: "#PID" <> format(pid)
  def inspect_fun(term, opts), do: Inspect.inspect(term, opts)

  defp normalize_format(format) when format in @formats, do: format
  defp normalize_format(_format), do: :distribution

  defp pid_to_string(pid) when is_pid(pid), do: display(pid)
  defp pid_to_string(pid) when is_binary(pid), do: pid

  defp maybe_localize(pid_string, :distribution), do: pid_string

  defp maybe_localize(pid_string, :local) do
    node_id = cached_node_id() || "\\d+"
    String.replace(pid_string, ~r/^<#{node_id}\.(\d+\.\d+)>$/, "<0.\\1>")
  end
end
