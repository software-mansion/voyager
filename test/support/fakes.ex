defmodule Voyager.Fakes do
  @moduledoc """
  Test fakes: canned `:erpc` replies shaped to satisfy the node-info snapshot
  builders, plus helpers for injecting an active `Voyager.NodeSession`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Voyager.NodeSession
  alias Voyager.NodeSession.Session

  @doc """
  Builds a `Voyager.NodeSession.Session` with sensible defaults.
  """
  @spec node_session(keyword()) :: Session.t()
  def node_session(attrs \\ []) do
    %Session{
      node: Keyword.get(attrs, :node, :demo@localhost),
      node_name: Keyword.get(attrs, :node_name, "demo@localhost"),
      cookie: Keyword.get(attrs, :cookie, "secret"),
      connected_at: Keyword.get(attrs, :connected_at, DateTime.utc_now())
    }
  end

  @doc """
  Injects `session` into the running `Voyager.NodeSession` GenServer and
  restores the previous state on test exit. Returns the injected session.
  """
  @spec connect_node!(Session.t()) :: Session.t()
  def connect_node!(session) do
    previous_state = :sys.get_state(NodeSession)
    previous_via = NodeSession.cached_connector_name()
    put_session(session)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> previous_state end)
      :persistent_term.put(:connected_via, previous_via)
    end)

    session
  end

  @doc """
  Overwrites the `Voyager.NodeSession` GenServer state with `session`
  (or `nil` to simulate no active connection). Does not register a restore.
  """
  @spec put_session(Session.t() | nil) :: :ok
  def put_session(session) do
    :sys.replace_state(NodeSession, fn state -> Map.put(state, :session, session) end)
    :ok
  end

  @default_node_data %{
    # System info
    otp_release: "27",
    erts_version: "15.2",
    system_version: "Erlang/OTP 27 [erts-15.2]",
    system_architecture: "aarch64-apple-darwin23",
    wordsize: 8,
    async_threads: 1,
    # Limits
    atom_count: 12_345,
    atom_limit: 1_048_576,
    process_count: 240,
    process_limit: 262_144,
    port_count: 12,
    port_limit: 65_536,
    # Schedulers
    schedulers: 8,
    schedulers_online: 8,
    dirty_cpu_schedulers: 8,
    dirty_cpu_schedulers_online: 8,
    dirty_io_schedulers: 10,
    # Statistics
    uptime_ms: 123_456,
    io_input: 1_000,
    io_output: 2_000,
    reductions: 5_000_000,
    run_queue_total: 3,
    run_queue_normal_and_dirty_cpu: 2,
    # Memory (bytes)
    mem_total: 100_000_000,
    mem_processes: 40_000_000,
    mem_processes_used: 39_000_000,
    mem_atom: 1_000_000,
    mem_atom_used: 900_000,
    mem_binary: 5_000_000,
    mem_code: 20_000_000,
    mem_ets: 3_000_000,
    # Application versions (nil => app not installed)
    stdlib_version: "5.2",
    elixir_version: "1.18.0",
    gleam_version: nil,
    # Running applications: {name, description, version}
    applications: [
      {:kernel, "ERTS  CXC 138 10", "9.2"},
      {:stdlib, "ERTS  CXC 138 10", "5.2"}
    ],
    application_masters: %{kernel: true, stdlib: false}
  }

  @doc """
  Returns a node-info data map (with sensible defaults) describing every value
  the mocked node would report. Pass `overrides` to control specific fields.

  Tests own this map and derive their expected rendered values from it, so
  assertions never depend on magic constants hidden in this module.
  """
  @spec node_data(map() | keyword()) :: map()
  def node_data(overrides \\ %{}), do: Map.merge(@default_node_data, Map.new(overrides))

  @doc """
  Canned reply for a mocked `:erpc.call/4`, shaped from `data` (see
  `node_data/1`) and dispatched on the module/function and arguments the
  `Voyager.Services.NodeInfo` collector issues.
  """
  def erpc_reply(:lists, :map, [fun, list], data) do
    if fun == (&:application_controller.get_master/1) do
      Enum.map(list, &application_master_reply(&1, data))
    else
      Enum.map(list, &system_value(&1, data))
    end
  end

  def erpc_reply(:erlang, :memory, [], data), do: memory_kw(data)

  def erpc_reply(:application, :get_key, [:stdlib, :vsn], data),
    do: version_reply(data.stdlib_version)

  def erpc_reply(:application, :get_key, [:elixir, :vsn], data),
    do: version_reply(data.elixir_version)

  def erpc_reply(:application, :get_key, [:gleam_stdlib, :vsn], data),
    do: version_reply(data.gleam_version)

  def erpc_reply(:application, :get_key, [_app, :vsn], _data), do: :undefined

  def erpc_reply(:application, :which_applications, [], data) do
    Enum.map(data.applications, fn {name, desc, vsn} ->
      {name, to_charlist(desc), to_charlist(vsn)}
    end)
  end

  # Mirrors what :erlang.system_info/1 and :erlang.statistics/1 return per key.
  defp system_value(:otp_release, d), do: to_charlist(d.otp_release)
  defp system_value(:version, d), do: to_charlist(d.erts_version)
  defp system_value(:system_version, d), do: to_charlist(d.system_version)
  defp system_value(:system_architecture, d), do: to_charlist(d.system_architecture)
  defp system_value({:wordsize, :internal}, d), do: d.wordsize
  defp system_value(:thread_pool_size, d), do: d.async_threads
  defp system_value(:atom_count, d), do: d.atom_count
  defp system_value(:atom_limit, d), do: d.atom_limit
  defp system_value(:process_count, d), do: d.process_count
  defp system_value(:process_limit, d), do: d.process_limit
  defp system_value(:port_count, d), do: d.port_count
  defp system_value(:port_limit, d), do: d.port_limit
  defp system_value(:schedulers, d), do: d.schedulers
  defp system_value(:schedulers_online, d), do: d.schedulers_online
  defp system_value(:dirty_cpu_schedulers, d), do: d.dirty_cpu_schedulers
  defp system_value(:dirty_cpu_schedulers_online, d), do: d.dirty_cpu_schedulers_online
  defp system_value(:dirty_io_schedulers, d), do: d.dirty_io_schedulers
  defp system_value(:wall_clock, d), do: {d.uptime_ms, 0}
  defp system_value(:io, d), do: {{:input, d.io_input}, {:output, d.io_output}}
  defp system_value(:reductions, d), do: {d.reductions, 0}
  defp system_value(:total_run_queue_lengths_all, d), do: d.run_queue_total
  defp system_value(:total_run_queue_lengths, d), do: d.run_queue_normal_and_dirty_cpu

  defp memory_kw(d) do
    [
      total: d.mem_total,
      processes: d.mem_processes,
      processes_used: d.mem_processes_used,
      atom: d.mem_atom,
      atom_used: d.mem_atom_used,
      binary: d.mem_binary,
      code: d.mem_code,
      ets: d.mem_ets
    ]
  end

  defp application_master_reply(app_name, data) do
    if Map.get(data.application_masters, app_name, true),
      do: :mock_application_master,
      else: :undefined
  end

  defp version_reply(nil), do: :undefined
  defp version_reply(vsn), do: {:ok, to_charlist(vsn)}
end
