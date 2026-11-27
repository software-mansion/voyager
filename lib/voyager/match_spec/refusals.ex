defmodule Voyager.MatchSpec.Refusals do
  @moduledoc """
  What the agent refuses in a match spec, for trace and ETS select alike, compiled into it as
  macros. Must not depend on `Voyager.Agent`, whose module name hashes these values.
  """

  @max_match_spec_bytes 65_536

  @spec agent_macros() :: keyword()
  def agent_macros, do: [MAX_MATCH_SPEC_BYTES: @max_match_spec_bytes]

  @doc "The largest encoded match spec the agent takes."
  @spec max_match_spec_bytes() :: pos_integer()
  def max_match_spec_bytes, do: @max_match_spec_bytes
end
