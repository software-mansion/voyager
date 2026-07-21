defmodule VoyagerWeb.FormSchemas.SshConnectionParams do
  use Ecto.Schema
  import Ecto.Changeset

  alias Voyager.Services.Erlssh.Auth

  @primary_key false
  embedded_schema do
    field :ssh_user, :string
    field :ssh_host, :string
    field :ssh_port, :integer, default: 22
    field :node_name, :string
    field :cookie, :string
    field :name_type, Ecto.Enum, values: [:shortnames, :longnames], default: :longnames
    field :auth_method, Ecto.Enum, values: [:agent, :password], default: :agent
    field :password, :string
    field :epmd_port, :integer, default: 4369
    field :remember_cookie, :boolean, default: false
    field :remember_password, :boolean, default: false
  end

  @type t :: %__MODULE__{
          ssh_user: String.t() | nil,
          ssh_host: String.t() | nil,
          ssh_port: integer(),
          node_name: String.t() | nil,
          cookie: String.t() | nil,
          name_type: :shortnames | :longnames,
          auth_method: :agent | :password,
          password: String.t() | nil,
          epmd_port: integer(),
          remember_cookie: boolean(),
          remember_password: boolean()
        }

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [
      :ssh_user,
      :ssh_host,
      :ssh_port,
      :node_name,
      :cookie,
      :name_type,
      :auth_method,
      :password,
      :epmd_port,
      :remember_cookie,
      :remember_password
    ])
    |> validate_required([:ssh_user, :ssh_host, :node_name, :cookie])
    |> validate_format(:node_name, ~r/^[^@\s]+@[^@\s]+$/, message: "Use the name@host format")
    |> validate_length(:ssh_user, max: 255)
    |> validate_length(:ssh_host, max: 255)
    |> validate_length(:node_name, max: 255)
    |> validate_length(:cookie, max: 255)
    |> validate_number(:ssh_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_number(:epmd_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_password_when_required()
  end

  @spec to_auth(t()) :: Auth.auth()
  def to_auth(%__MODULE__{auth_method: :agent}), do: :agent

  def to_auth(%__MODULE__{auth_method: :password, password: pw}) when is_binary(pw),
    do: {:password, pw}

  defp validate_password_when_required(changeset) do
    case get_field(changeset, :auth_method) do
      :password -> validate_required(changeset, [:password])
      _ -> changeset
    end
  end
end
