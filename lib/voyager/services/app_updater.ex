defmodule Voyager.Services.AppUpdater do
  @moduledoc """
  Tracks the desktop app update announced by the Tauri shell over `ElixirKit.PubSub`
  and asks the shell to install it. Every change is broadcast on `topic/0` as
  `{:app_update, update}`.
  """

  use GenServer

  @type update :: %{version: String.t(), status: :available | :installing | :failed} | nil

  @native_topic "updates"
  @pubsub_topic "app_update"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  @spec current() :: update()
  def current, do: GenServer.call(__MODULE__, :current)

  @doc """
  Asks the Tauri shell to download and install the update. On success the app restarts,
  on failure the status becomes `:failed` so the user can retry.
  """
  @spec install() :: :ok | {:error, :no_update}
  def install, do: GenServer.call(__MODULE__, :install)

  @impl GenServer
  def init(opts) do
    if Keyword.fetch!(opts, :native?), do: ElixirKit.PubSub.subscribe(@native_topic)

    {:ok, nil}
  end

  @impl GenServer
  def handle_call(:current, _from, update), do: {:reply, update, update}

  def handle_call(:install, _from, %{status: status} = update)
      when status in [:available, :failed] do
    ElixirKit.PubSub.broadcast(@native_topic, "install")

    {:reply, :ok, put_update(%{update | status: :installing})}
  end

  def handle_call(:install, _from, update), do: {:reply, {:error, :no_update}, update}

  @impl GenServer
  def handle_info("available:" <> version, _update) do
    {:noreply, put_update(%{version: version, status: :available})}
  end

  def handle_info("failed", %{} = update) do
    {:noreply, put_update(%{update | status: :failed})}
  end

  def handle_info(_message, update), do: {:noreply, update}

  defp put_update(update) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, {:app_update, update})
    update
  end
end
