defmodule Voyager.Services.TermSyntax do
  @moduledoc """
  Which language's syntax terms are displayed in: `:elixir` or `:erlang`.

  The `:term_syntax` setting is `:auto`, `:elixir` or `:erlang`. `:auto` follows
  the connected node: Erlang when it has no `:elixir` application, Elixir
  otherwise. The setting and the connected node's syntax are cached in
  `:persistent_term`; only the first `get_setting/0` reads the database.
  """

  alias Voyager.Erpc
  alias Voyager.Settings

  @setting_key {__MODULE__, :setting}
  @node_syntax {__MODULE__, :node}
  @settings [:auto, :elixir, :erlang]

  @type syntax :: :elixir | :erlang
  @type setting :: :auto | syntax()

  @doc "The syntax to render with: the setting, with `:auto` resolved against the connected node."
  @spec current() :: syntax()
  def current do
    case get_setting() do
      :auto -> :persistent_term.get(@node_syntax, :elixir)
      syntax -> syntax
    end
  end

  @doc "The saved setting; `:auto` when none is saved or the saved value is unknown."
  @spec get_setting() :: setting()
  def get_setting, do: Settings.get_cached_choice(:term_syntax, @settings, :auto, @setting_key)

  @spec setting_locked?() :: boolean()
  def setting_locked?, do: Settings.locked?(:term_syntax)

  @doc "Saves `setting`, given as an atom or its name, and caches it."
  @spec save_setting(setting() | String.t()) ::
          {:ok, setting()} | {:error, :unsupported_choice | :locked | Ecto.Changeset.t()}
  def save_setting(setting),
    do: Settings.save_cached_choice(:term_syntax, @settings, setting, @setting_key)

  @doc "Caches the syntax `:auto` resolves to for `node`; an unreachable node counts as Elixir."
  @spec put_node(node() | nil) :: :ok
  def put_node(nil), do: :persistent_term.put(@node_syntax, :elixir)
  def put_node(node), do: :persistent_term.put(@node_syntax, node_syntax(node))

  defp node_syntax(node) do
    case Erpc.safe_call(node, :application, :get_key, [:elixir, :vsn]) do
      {:ok, :undefined} -> :erlang
      _loaded_or_error -> :elixir
    end
  end
end
