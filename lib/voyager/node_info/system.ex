defmodule Voyager.NodeInfo.System do
  @moduledoc """
  System-level facts about a BEAM node: OTP/ERTS versions, architecture,
  scheduler counts, and detected BEAM-hosted languages.

  Passive module: declares the `:erlang.system_info/1` keys it needs via
  `system_info_keys/0`, and builds its struct from pre-fetched data via
  `build/2`. The RPC against the target node is owned by
  `Voyager.NodeInfo`, which batches keys from all sub-modules into a
  single remote `:lists.map(&:erlang.system_info/1, keys)` call.
  """

  alias __MODULE__

  @system_info_keys [
    :otp_release,
    :version,
    :system_version,
    :system_architecture,
    {:wordsize, :internal},
    {:wordsize, :external},
    :smp_support,
    :threads,
    :thread_pool_size,
    :logical_processors,
    :logical_processors_online,
    :logical_processors_available,
    :schedulers,
    :schedulers_online
  ]

  @type language :: %{name: String.t(), version: String.t()}

  @type t :: %__MODULE__{
          otp_release: String.t(),
          erts_version: String.t(),
          system_version: String.t(),
          system_architecture: String.t(),
          wordsize_internal: pos_integer(),
          wordsize_external: pos_integer(),
          smp_support?: boolean(),
          thread_support?: boolean(),
          async_threads: non_neg_integer(),
          logical_processors: pos_integer() | :unknown,
          logical_processors_online: pos_integer() | :unknown,
          logical_processors_available: pos_integer() | :unknown,
          schedulers: pos_integer(),
          schedulers_online: pos_integer()
        }

  defstruct [
    :otp_release,
    :erts_version,
    :system_version,
    :system_architecture,
    :wordsize_internal,
    :wordsize_external,
    :smp_support?,
    :thread_support?,
    :async_threads,
    :logical_processors,
    :logical_processors_online,
    :logical_processors_available,
    :schedulers,
    :schedulers_online
  ]

  @spec system_info_keys() :: [atom() | tuple()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(si) do
    otp_release = si |> Map.fetch!(:otp_release) |> to_string()

    %System{
      otp_release: otp_release,
      erts_version: si |> Map.fetch!(:version) |> to_string(),
      system_version: si |> Map.fetch!(:system_version) |> to_string() |> String.trim(),
      system_architecture: si |> Map.fetch!(:system_architecture) |> to_string(),
      wordsize_internal: Map.fetch!(si, {:wordsize, :internal}),
      wordsize_external: Map.fetch!(si, {:wordsize, :external}),
      smp_support?: Map.fetch!(si, :smp_support),
      thread_support?: Map.fetch!(si, :threads),
      async_threads: Map.fetch!(si, :thread_pool_size),
      logical_processors: Map.fetch!(si, :logical_processors),
      logical_processors_online: Map.fetch!(si, :logical_processors_online),
      logical_processors_available: Map.fetch!(si, :logical_processors_available),
      schedulers: Map.fetch!(si, :schedulers),
      schedulers_online: Map.fetch!(si, :schedulers_online)
    }
  end
end
