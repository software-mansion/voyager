defmodule Voyager.Pid do
  @moduledoc """
  Converts PIDs to and from their `"<X.Y.Z>"` string representation and
  formats them for display. The display format and the connected node's id
  are cached in `:persistent_term`, so formatting never makes a call.
  """

  alias Voyager.Erpc
  alias Voyager.Settings

  @format_key {__MODULE__, :format}
  @node_id_key {__MODULE__, :node_id}
  @formats [:distribution, :local]

  @spec parse(String.t()) :: pid() | nil
  def parse(pid_str) when is_binary(pid_str) do
    pid_str |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  @doc "The `N` of the connected node's `<N.X.Y>` pids, cached by `put_node/1`."
  @spec cached_node_id() :: String.t() | nil
  def cached_node_id, do: :persistent_term.get(@node_id_key, nil)

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
  Formats a PID for display. Omitting the format uses `cached_format/0`.
  `:local` shortens only the connected node's pids.

      iex> Voyager.Pid.format("<123.23.423>", :distribution)
      "<123.23.423>"
  """
  @spec format(pid() | String.t(), :distribution | :local) :: String.t()
  def format(pid, format \\ cached_format()) when format in @formats do
    pid
    |> pid_to_string()
    |> maybe_localize(format)
  end

  @doc "An `:inspect_fun` that renders every pid, however deeply nested, via `format/1`."
  @spec inspect_fun(term(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect_fun(pid, _opts) when is_pid(pid), do: "#PID" <> format(pid)
  def inspect_fun(term, opts), do: Inspect.inspect(term, opts)

  # Any pid of the node, printed here, carries the `N` this node gives it.
  defp node_id(node) do
    case Erpc.safe_call(node, :erlang, :self, []) do
      {:ok, pid} when is_pid(pid) ->
        [_prefix, id] = Regex.run(~r/^<(\d+)\./, format(pid, :distribution))
        id

      _error ->
        nil
    end
  end

  defp normalize_format(format) when format in @formats, do: format
  defp normalize_format(_format), do: :distribution

  defp pid_to_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp pid_to_string(pid) when is_binary(pid), do: pid

  defp maybe_localize(pid_string, :distribution), do: pid_string

  defp maybe_localize(pid_string, :local) do
    node_id = cached_node_id()

    if node_id && Regex.match?(~r/^<\d+\.\d+\.\d+>$/, pid_string) do
      String.replace_prefix(pid_string, "<#{node_id}.", "<0.")
    else
      pid_string
    end
  end
end
