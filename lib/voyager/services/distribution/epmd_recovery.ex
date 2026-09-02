defmodule Voyager.Services.Distribution.EpmdRecovery do
  @moduledoc false

  @type action :: :keep_distribution | :restart_distribution

  @spec action(
          initially_running? :: boolean(),
          start_result :: :ok | {:error, term()},
          running_after_start? :: boolean()
        ) :: action()
  def action(true, _start_result, _running_after_start?),
    do: :keep_distribution

  def action(false, :ok, true),
    do: :keep_distribution

  def action(false, _start_result, _running_after_start?),
    do: :restart_distribution
end
