defmodule Voyager.Services.AppUpdater do
  @moduledoc """
  Tracks the desktop app update announced by the Tauri shell over `ElixirKit.PubSub`
  and asks the shell to check for or install one. Every change is broadcast on
  `topic/0` as `{:app_update, update}`.
  """

  use GenServer

  @type status ::
          :available
          | :dismissed
          | :installing
          | :failed
          | :checking
          | :up_to_date
          | :check_failed
  @type update :: %{version: String.t() | nil, status: status()} | nil

  @native_topic "updates"
  @pubsub_topic "app_update"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  @doc "Whether a Tauri shell is attached, so checks and installs can be requested."
  @spec supported?() :: boolean()
  def supported?, do: GenServer.call(__MODULE__, :supported?)

  @spec current() :: update()
  def current, do: GenServer.call(__MODULE__, :current)

  @doc """
  Asks the Tauri shell to download and install the update. On success the app restarts,
  on failure the status becomes `:failed` so the user can retry.
  """
  @spec install() :: :ok | {:error, :no_update}
  def install, do: GenServer.call(__MODULE__, :install)

  @spec dismiss() :: :ok
  def dismiss, do: GenServer.call(__MODULE__, :dismiss)

  @spec check() :: :ok
  def check, do: GenServer.call(__MODULE__, :check)

  @impl GenServer
  def init(opts) do
    native? = Keyword.fetch!(opts, :native?)
    if native?, do: ElixirKit.PubSub.subscribe(@native_topic)

    {:ok, %{native?: native?, update: nil}}
  end

  @impl GenServer
  def handle_call(:supported?, _from, state), do: {:reply, state.native?, state}
  def handle_call(:current, _from, state), do: {:reply, state.update, state}

  def handle_call(:install, _from, %{update: %{status: status}} = state)
      when status in [:available, :dismissed, :failed] do
    ElixirKit.PubSub.broadcast(@native_topic, "install")

    {:reply, :ok, put_status(state, :installing)}
  end

  def handle_call(:install, _from, state), do: {:reply, {:error, :no_update}, state}

  def handle_call(:dismiss, _from, %{update: %{status: status}} = state)
      when status in [:available, :failed] do
    {:reply, :ok, put_status(state, :dismissed)}
  end

  def handle_call(:dismiss, _from, state), do: {:reply, :ok, state}

  def handle_call(:check, _from, state) do
    ElixirKit.PubSub.broadcast(@native_topic, "check")

    {:reply, :ok, put_update(state, %{version: nil, status: :checking})}
  end

  @impl GenServer
  def handle_info("available:" <> version, state) do
    {:noreply, put_update(state, %{version: version, status: :available})}
  end

  # The startup check stays silent when nothing is new, only a manual one reports it.
  def handle_info("none", %{update: %{status: :checking}} = state) do
    {:noreply, put_status(state, :up_to_date)}
  end

  def handle_info("check_failed", %{update: %{status: :checking}} = state) do
    {:noreply, put_status(state, :check_failed)}
  end

  def handle_info("failed", %{update: %{status: :installing}} = state) do
    {:noreply, put_status(state, :failed)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_status(state, status), do: put_update(state, %{state.update | status: status})

  defp put_update(state, update) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, {:app_update, update})
    %{state | update: update}
  end
end
