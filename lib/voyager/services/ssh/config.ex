defmodule Voyager.Services.SSH.Config do
  @moduledoc false

  alias Voyager.Services.LocalFiles

  @type host :: %{
          alias: String.t(),
          host_name: String.t() | nil,
          user: String.t() | nil,
          port: :inet.port_number() | nil,
          identity_files: [Path.t()],
          identity_agent: Path.t() | :none | nil
        }

  @type unsupported :: %{keyword: String.t(), type: :keyword | :block | :value}

  @type result :: %{hosts: [host()], unsupported: [unsupported()]}

  @spec read(Path.t()) :: {:ok, result()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path \\ "~/.ssh/config") do
    with {:ok, contents} <- LocalFiles.read(path), do: {:ok, parse(contents)}
  end

  @spec parse(String.t()) :: result()
  def parse(_contents), do: %{hosts: [], unsupported: []}
end
