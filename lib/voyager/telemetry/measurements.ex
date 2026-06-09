defmodule Voyager.Telemetry.Measurements do
  @moduledoc """
  Builders for telemetry measurement payloads.
  """

  @doc "Subset of `:erlang.memory/0` suitable for export and LiveDashboard summaries."
  @spec vm_memory() :: map()
  def vm_memory do
    memory = :erlang.memory()

    %{
      total: memory[:total],
      processes: memory[:processes],
      atom: memory[:atom],
      ets: memory[:ets],
      binary: memory[:binary],
      code: memory[:code],
      system: memory[:system]
    }
  end
end
