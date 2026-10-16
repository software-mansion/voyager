defmodule VoyagerWeb.ConnectLive.KeyAuth do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Phoenix.LiveView.Socket
  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.SSH.KeyFile
  alias VoyagerWeb.ConnectLive.ConnectError
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:passphrase_form, nil)
    |> assign(:key_passphrase, nil)
    |> attach_hook(:key_auth, :handle_event, &handle_event/3)
  end

  @spec checked_form(Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def checked_form(changeset) do
    form = to_form(changeset, as: :ssh)
    %{form | errors: add_error(changeset).errors -- changeset.errors}
  end

  @spec add_error(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def add_error(changeset) do
    case changeset |> Ecto.Changeset.apply_changes() |> check() do
      :ok ->
        changeset

      {:error, reason} ->
        Ecto.Changeset.add_error(changeset, :key_path, ConnectError.message(reason))
    end
  end

  @spec restore(Socket.t(), SshConnection.t()) :: Socket.t()
  def restore(socket, %SshConnection{} = conn),
    do: assign(socket, :key_passphrase, conn.passphrase && {conn.key_path, conn.passphrase})

  @spec connect(Socket.t(), SshConnectionParams.t(), (Socket.t(), SshConnectionParams.t() ->
                                                        Socket.t())) :: Socket.t()
  def connect(socket, %SshConnectionParams{auth_method: :key} = p, start) do
    p = %{
      p
      | passphrase: p.passphrase || saved_passphrase(socket.assigns.key_passphrase, p.key_path)
    }

    case KeyFile.check(p.key_path, p.passphrase) do
      {:error, reason} when reason in [:key_passphrase_required, :key_bad_passphrase] ->
        assign(socket, :passphrase_form, passphrase_form(reason, p.remember_passphrase))

      _ ->
        socket
        |> assign(:passphrase_form, nil)
        |> assign(:key_passphrase, p.passphrase && {p.key_path, p.passphrase})
        |> start.(p)
    end
  end

  def connect(socket, %SshConnectionParams{} = p, start), do: start.(socket, p)

  defp handle_event("change_passphrase", %{"passphrase" => params}, socket),
    do: {:halt, assign(socket, :passphrase_form, to_form(params, as: :passphrase))}

  defp handle_event("cancel_passphrase", _params, socket),
    do: {:halt, assign(socket, :passphrase_form, nil)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp check(%SshConnectionParams{auth_method: :key, key_path: path}) when is_binary(path) do
    case KeyFile.check(path, nil) do
      {:error, :key_passphrase_required} -> :ok
      result -> result
    end
  end

  defp check(%SshConnectionParams{}), do: :ok

  defp passphrase_form(reason, remember) do
    errors =
      if reason == :key_bad_passphrase, do: [passphrase: {"Wrong passphrase", []}], else: []

    to_form(%{"remember" => to_string(remember)}, as: :passphrase, errors: errors)
  end

  defp saved_passphrase({path, passphrase}, path), do: passphrase
  defp saved_passphrase(_saved, _path), do: nil
end
