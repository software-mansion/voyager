defmodule Voyager.Services.TermSyntax do
  @moduledoc """
  Which language's syntax terms are displayed in: `:elixir` or `:erlang`.

  The `:term_syntax` setting is `:auto`, `:elixir` or `:erlang`. `:auto` follows
  the connected node: Erlang when it has no `:elixir` application, Elixir
  otherwise. The setting and the connected node's syntax are cached in
  `:persistent_term`, so `current/0` never makes a call.
  """

  alias Voyager.Erpc
  alias Voyager.Settings

  @setting_key {__MODULE__, :setting}
  @node_key {__MODULE__, :node}
  @settings [:auto, :elixir, :erlang]

  @type syntax :: :elixir | :erlang
  @type setting :: :auto | syntax()

  @doc "The syntax to render with: the setting, with `:auto` resolved against the connected node."
  @spec current() :: syntax()
  def current do
    case cached_setting() do
      :auto -> :persistent_term.get(@node_key, :elixir)
      syntax -> syntax
    end
  end

  @doc "The setting cached by `load_setting/0` or `put_setting/1`; `:auto` until either runs."
  @spec cached_setting() :: setting()
  def cached_setting, do: :persistent_term.get(@setting_key, :auto)

  @doc "Reads the `:term_syntax` setting into the cache. Unknown values fall back to `:auto`."
  @spec load_setting() :: :ok
  def load_setting do
    :term_syntax
    |> Settings.get_choice(@settings, :auto)
    |> put_setting()
  end

  @spec put_setting(setting()) :: :ok
  def put_setting(setting) when setting in @settings do
    :persistent_term.put(@setting_key, setting)
  end

  @doc "Caches the syntax `:auto` resolves to for `node`; an unreachable node counts as Elixir."
  @spec put_node(node() | nil) :: :ok
  def put_node(nil), do: :persistent_term.put(@node_key, :elixir)
  def put_node(node), do: :persistent_term.put(@node_key, node_syntax(node))

  defp node_syntax(node) do
    case Erpc.safe_call(node, :application, :get_key, [:elixir, :vsn]) do
      {:ok, :undefined} -> :erlang
      _loaded_or_error -> :elixir
    end
  end
end
