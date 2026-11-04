defmodule Voyager.Services.Tracer.Refusals do
  @moduledoc """
  What the agent refuses to trace, compiled into it as macros and checked by
  `Voyager.Services.Tracer.Config`. Must not depend on `Voyager.Agent`, whose
  module name hashes these lists.
  """

  @always_refused [:trace]
  # Called from nearly every process: an all-process call trace on them floods the tracer.
  @hot ~w(erlang lists maps ets gen gen_server gen_statem gen_event proc_lib io io_lib logger
          timer code erl_eval Elixir.Enum Elixir.Map Elixir.Kernel Elixir.String Elixir.GenServer
          erpc rpc gen_tcp inet ssl net_kernel dist_util proplists persistent_term unicode binary
          telemetry Elixir.Keyword Elixir.Access Elixir.Enumerable Elixir.List)a
  @hot_prefixes ["prim_", "erts_"]
  @refused_actions ~w(trace enable_trace disable_trace silent set_seq_token process_dump display
                      current_stacktrace caller_line set_tcw return_trace exception_trace)a

  @spec agent_macros() :: keyword()
  def agent_macros do
    [
      TRACE_ALWAYS_REFUSED: @always_refused,
      TRACE_HOT: @hot,
      TRACE_HOT_PREFIXES: Enum.map(@hot_prefixes, &String.to_charlist/1),
      TRACE_REFUSED_ACTIONS: @refused_actions
    ]
  end

  @doc "Refused even on selected pids. The agent also refuses itself."
  @spec always_refused?(String.t()) :: boolean()
  def always_refused?(module), do: module in Enum.map(@always_refused, &Atom.to_string/1)

  @doc "Refused unless the session traces selected pids."
  @spec hot?(String.t()) :: boolean()
  def hot?(module),
    do: module in Enum.map(@hot, &Atom.to_string/1) or String.starts_with?(module, @hot_prefixes)
end
