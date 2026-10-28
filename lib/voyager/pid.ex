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

  @type format :: :distribution | :local

  @spec parse(String.t()) :: pid() | nil
  def parse(pid_string) when is_binary(pid_string) do
    pid_string |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  @doc """
  Resolves a pid string to a pid of `node`. The normal form embeds this node's
  index for the owning node and parses locally; a `<0.X.Y>` string names a
  process only on the node that prints it, so it is resolved there.
  """
  @spec resolve(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  def resolve(node, "#PID" <> pid_string), do: resolve(node, pid_string)

  def resolve(node, "<0." <> _rest = pid_string) do
    Erpc.safe_call(node, :erlang, :list_to_pid, [String.to_charlist(pid_string)])
  end

  def resolve(node, pid_string) do
    case parse(pid_string) do
      pid when is_pid(pid) and node(pid) == node -> {:ok, pid}
      _other -> {:error, :invalid_pid}
    end
  end

  @doc "The `N` of the connected node's `<N.X.Y>` pids, cached by `put_node/1`."
  @spec cached_node_id() :: String.t() | nil
  def cached_node_id, do: :persistent_term.get(@node_id_key, nil)

  @spec put_node(node() | nil) :: :ok
  def put_node(nil), do: :persistent_term.put(@node_id_key, nil)
  def put_node(node), do: :persistent_term.put(@node_id_key, node_id(node))

  @spec settings() :: [format()]
  def settings, do: @formats

  @doc """
  The saved PID format setting; `:distribution` when none is saved or the saved
  value is unknown. Only the first call reads the database.
  """
  @spec get_setting() :: format()
  def get_setting,
    do: Settings.get_cached_choice(:pid_format, @formats, :distribution, @format_key)

  @spec setting_locked?() :: boolean()
  def setting_locked?, do: Settings.locked?(:pid_format)

  @doc "Saves `format` and caches it; `{:error, :locked}` when application config sets it."
  @spec save_setting(format()) :: :ok | {:error, :locked | Ecto.Changeset.t()}
  def save_setting(format) when format in @formats,
    do: Settings.save_with_cache(:pid_format, format, @format_key)

  @doc """
  Formats a PID for display. Omitting the format uses `get_setting/0`.
  `:local` shortens only the connected node's pids.

      iex> Voyager.Pid.format("<123.23.423>", :distribution)
      "<123.23.423>"
  """
  @spec format(pid() | String.t(), format()) :: String.t()
  def format(pid, format \\ get_setting()) when format in @formats do
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
