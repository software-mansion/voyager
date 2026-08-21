defmodule Voyager.Settings do
  @moduledoc """
  Key-value settings service backed by the database.

  **Always use this service** — never query the `settings` table directly.
  Every read goes through config-priority logic so that application config
  (config.exs / runtime.exs) can override any DB value.

  Keys are atoms and map directly to `Application.get_env(:voyager, key)`.
  Values are serialized with `:erlang.term_to_binary` so any Elixir term
  round-trips correctly through the database.

  ## Config priority

  If the key is present in `:voyager` application config it is returned as-is
  and the database is not consulted. Use `locked?/1` to check whether a key is
  controlled by config before allowing UI changes.

  ## Usage

      # Read with config priority, DB fallback, then default
      Settings.get(:mcp_port, 4040)

      # Persist to DB (does not modify application config)
      Settings.put(:mcp_port, 5000)

      # Check whether config controls this key (UI should disable editing)
      Settings.locked?(:mcp_port)

  Successful `put/2` calls broadcast `{:setting_changed, key, value}` on
  `topic(key)` so LiveViews can keep a cached assign in sync.
  """

  import Ecto.Query

  alias Voyager.Repo
  alias Voyager.Schemas.Setting

  @pubsub_topic_base "settings"

  @doc "PubSub topic for changes to a single setting key."
  @spec topic(atom()) :: String.t()
  def topic(key) when is_atom(key), do: "#{@pubsub_topic_base}:#{key}"

  @doc """
  Gets a setting value.

  Checks `:voyager` application config first. If not set there, reads from the
  database. Returns `default` when neither source has the key.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    case Application.fetch_env(:voyager, key) do
      {:ok, value} ->
        value

      :error ->
        case db_get(Atom.to_string(key)) do
          nil -> default
          encoded -> decode(encoded)
        end
    end
  end

  @doc """
  Persists a setting to the database.

  Options:
  - `:broadcast?` (boolean): Whether to broadcast the setting change to the pubsub topic. Default is `false`.

  Returns `{:error, :locked}` when the key is set in application config.
  """
  @spec put(atom(), term(), Keyword.t()) ::
          {:ok, Setting.t()} | {:error, :locked} | {:error, Ecto.Changeset.t()}
  def put(key, value, options \\ []) when is_atom(key) do
    broadcast? = Keyword.get(options, :broadcast?, false)

    with false <- locked?(key),
         {:ok, setting} <- insert_setting(key, value) do
      if broadcast? do
        Phoenix.PubSub.broadcast(Voyager.PubSub, topic(key), {:setting_changed, key, value})
      end

      {:ok, setting}
    else
      true -> {:error, :locked}
      error -> error
    end
  end

  defp insert_setting(key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    db_key = Atom.to_string(key)
    encoded = encode(value)

    %Setting{}
    |> Setting.changeset(%{key: db_key, value: encoded})
    |> Repo.insert(
      on_conflict: [set: [value: encoded, updated_at: now]],
      conflict_target: :key
    )
  end

  @doc """
  Returns `true` when the key is set in `:voyager` application config.

  A locked setting cannot be meaningfully changed via the database - the config
  value always takes priority. Use this to disable UI editing for such keys.
  """
  @spec locked?(atom()) :: boolean()
  def locked?(key) when is_atom(key) do
    match?({:ok, _}, Application.fetch_env(:voyager, key))
  end

  @doc "Returns all persisted settings as a map of string key => decoded value."
  @spec all() :: %{String.t() => term()}
  def all do
    Repo.all(from s in Setting, select: {s.key, s.value})
    |> Map.new(fn {key, encoded} -> {key, decode(encoded)} end)
  end

  defp db_get(key) do
    Repo.one(from s in Setting, where: s.key == ^key, select: s.value)
  end

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()
  defp decode(encoded), do: encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
end
