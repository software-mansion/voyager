defmodule Voyager.NodeInfo.SystemInfo do
  @moduledoc """
  System-level facts about a BEAM node.
  """

  @system_info_keys [
    :otp_release,
    :version,
    :system_version,
    :system_architecture,
    {:wordsize, :internal},
    {:wordsize, :external},
    :smp_support,
    :threads,
    :thread_pool_size
  ]

  @type t :: %__MODULE__{
          otp_release: String.t(),
          erts_version: String.t(),
          system_version: String.t(),
          system_architecture: String.t(),
          wordsize_internal: pos_integer(),
          wordsize_external: pos_integer(),
          smp_support?: boolean(),
          thread_support?: boolean(),
          async_threads: non_neg_integer()
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
    :async_threads
  ]

  @spec system_info_keys() :: [atom() | tuple()]
  def system_info_keys, do: @system_info_keys

  @spec build(map()) :: t()
  def build(system_info) do
    otp_release = system_info |> Map.fetch!(:otp_release) |> to_string()

    %__MODULE__{
      otp_release: otp_release,
      erts_version: system_info |> Map.fetch!(:version) |> to_string(),
      system_version: system_info |> Map.fetch!(:system_version) |> to_string() |> String.trim(),
      system_architecture: system_info |> Map.fetch!(:system_architecture) |> to_string(),
      wordsize_internal: Map.fetch!(system_info, {:wordsize, :internal}),
      wordsize_external: Map.fetch!(system_info, {:wordsize, :external}),
      smp_support?: Map.fetch!(system_info, :smp_support),
      thread_support?: Map.fetch!(system_info, :threads),
      async_threads: Map.fetch!(system_info, :thread_pool_size)
    }
  end
end
