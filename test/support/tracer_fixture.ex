defmodule Voyager.Test.TracerFixture do
  @moduledoc """
  Drives the app's `Tracer` against this VM from LiveView tests: `setup_tracer/1` loads
  the agent, swaps the erpc impl, resets the `Tracer` state and connects a node session,
  all undone on exit. Tests using it must be `async: false`.
  """

  use VoyagerWeb, :verified_routes

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture

  @endpoint VoyagerWeb.Endpoint
  @node_name "nonode@nohost"

  def node_name, do: @node_name

  def setup_tracer(_context) do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    previous_state = :sys.get_state(Tracer)
    :sys.replace_state(Tracer, fn _ -> %Tracer{} end)
    on_exit(fn -> :sys.replace_state(Tracer, fn _ -> previous_state end) end)

    on_exit(fn ->
      :sys.resume(Tracer)
      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)
      Writer.flush()
    end)

    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

  def create!(opts \\ []) do
    {:ok, session} = Tracer.create(:ui, opts)
    session
  end

  def configure(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          pids: [Voyager.Pid.format(self(), :distribution)],
          max_events: 1_000
        },
        overrides
      )

    Tracer.configure(Node.self(), attrs, :ui)
  end

  @doc "Creates, configures and starts a session, subscribing the caller to its broadcasts."
  def start!(overrides \\ %{}, opts \\ []) do
    session = create!(opts)
    {:ok, _session} = configure(overrides)
    {:ok, _session} = Tracer.start(:ui)
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    session
  end

  @doc "A configured saved session that a newer unsaved one has replaced in the tracer."
  def saved_inactive! do
    session = create!(save: true)
    {:ok, _session} = configure()
    create!()
    session
  end

  def call_traced!(calls, traces) do
    for _ <- 1..calls, do: Date.leap_year?(~D[2024-01-01])
    assert_receive {:session_entries, %{traces: ^traces}, _entries}, 2_000
  end

  def flush_log(view) do
    put_queued(view)
    send(view.pid, :flush_log)
    render(view)
  end

  # A stop lands as a broadcast once the remote tracer's done message reaches the Tracer.
  def settle(view) do
    render_async(view)
    put_queued(view)
  end

  @doc "Applies the session broadcasts the view throttles, without waiting for their timers."
  def put_queued(view) do
    # The broadcast reaches the view before the Tracer handles its next message.
    _ = :sys.get_state(Tracer)
    send(view.pid, :put_queued_session)
    send(view.pid, :put_tracing_session)
  end

  def row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#session-log-rows > tr")
    |> LazyHTML.attribute("id")
  end

  def open(conn, id) do
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{id}")
    render_async(view)
    view
  end
end
