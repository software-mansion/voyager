defmodule Voyager.TraceToolCase do
  @moduledoc """
  Test case for the MCP trace tools: traces `Date.leap_year?/1` in the test process
  on this node, through the real agent, with `Voyager.NodeSession` connected to it.
  """

  use ExUnit.CaseTemplate

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture

  using do
    quote do
      alias Anubis.Server.Frame
      alias Voyager.Services.Tracer

      import Voyager.TraceToolCase
    end
  end

  setup tags do
    Voyager.DataCase.setup_sandbox(tags)
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    Fakes.connect_node!(Fakes.node_session(node: node(), node_name: Atom.to_string(node())))

    reset_tracer()
    # The stop's DB write must land before the sandbox owner exits.
    on_exit(&reset_tracer/0)
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())

    :ok
  end

  # Other test modules leave their sessions active, and a running one cannot close.
  defp reset_tracer do
    Task.await(Task.async(&stop_running/0))
    Writer.flush()
    :ok = Tracer.close()
  end

  # In a task, so the session updates it subscribes to stay out of the test's mailbox.
  defp stop_running do
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.session_topic())

    if match?(%{status: :running}, Tracer.active()) do
      Tracer.stop(:ui)

      receive do
        {:session_updated, %{status: :stopped}} -> :ok
      after
        1_000 -> raise "the running tracing session did not stop"
      end
    end
  end

  @doc "Creates and configures a session tracing `Date.leap_year?/1` in the calling process."
  @spec configure(map(), keyword()) :: Tracer.Session.t()
  def configure(overrides \\ %{}, opts \\ []) do
    {:ok, _session} = Tracer.create(:ui, opts)
    {:ok, session} = Tracer.configure(node(), config_attrs(overrides), :ui)
    session
  end

  @spec config_attrs(map()) :: map()
  def config_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        module: "Elixir.Date",
        function: "leap_year?",
        arity: 1,
        pids: [Voyager.Pid.format(self(), :distribution)],
        capture: :args,
        return_trace: true,
        max_events: 1_000,
        max_time_ms: 5_000
      },
      overrides
    )
  end

  @doc "Calls `Date.leap_year?/1` `count` times and waits until the session logged them."
  @spec trace_calls(pos_integer()) :: :ok
  def trace_calls(count) do
    events = if Tracer.active().config.return_trace, do: count * 2, else: count
    traces = Tracer.active().traces + events
    Enum.each(1..count, fn year -> Date.leap_year?(Date.new!(2000 + year, 1, 1)) end)

    receive do
      {:session_entries, %{traces: ^traces}, _entries} -> :ok
    after
      1_000 -> ExUnit.Assertions.flunk("expected #{traces} trace events")
    end
  end

  @spec json!({:reply, Response.t(), Frame.t()}) :: map()
  def json!({:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}}),
    do: JSON.decode!(json)

  @spec error!({:reply, Response.t(), Frame.t()}) :: String.t()
  def error!({:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}}),
    do: text
end
