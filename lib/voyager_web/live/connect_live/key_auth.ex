defmodule VoyagerWeb.ConnectLive.KeyAuth do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4, start_async: 3, cancel_async: 2]

  alias Phoenix.LiveView.Socket
  alias Voyager.NodeSession.ConnectError
  alias Voyager.Services.SSH
  alias Voyager.Services.SSH.KeyFile
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @type start :: (Socket.t(), SshConnectionParams.t(), SSH.auth() -> Socket.t())

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:passphrase_form, nil)
    |> assign(:checking_passphrase?, false)
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

  @doc "A passphrase is checked in a `:key_decode` async; pass its result to `handle_decode/3`."
  @spec connect(Socket.t(), SshConnectionParams.t(), start()) :: Socket.t()
  def connect(socket, %SshConnectionParams{auth_method: :key, passphrase: nil} = p, start),
    do: decoded(socket, p, KeyFile.decode(p.key_path, nil), start)

  def connect(socket, %SshConnectionParams{auth_method: :key} = p, _start) do
    socket
    |> assign(:checking_passphrase?, true)
    |> start_async(:key_decode, fn -> {p, KeyFile.decode(p.key_path, p.passphrase)} end)
  end

  def connect(socket, %SshConnectionParams{} = p, start),
    do: start.(socket, p, SshConnectionParams.to_auth(p))

  @spec handle_decode(Socket.t(), {:ok, term()} | {:exit, term()}, start()) :: Socket.t()
  def handle_decode(socket, {:ok, {p, result}}, start) do
    socket
    |> assign(:checking_passphrase?, false)
    |> decoded(p, result, start)
  end

  def handle_decode(socket, {:exit, {:shutdown, :cancel}}, _start), do: socket

  def handle_decode(socket, {:exit, _reason}, _start) do
    socket
    |> assign(:checking_passphrase?, false)
    |> assign(:passphrase_form, nil)
    |> put_key_error(:unexpected_exit)
  end

  defp decoded(socket, p, {:ok, key}, start) do
    socket
    |> assign(:passphrase_form, nil)
    |> start.(p, {:key, key})
  end

  defp decoded(socket, _p, {:error, reason}, _start)
       when reason in [:key_passphrase_required, :key_bad_passphrase],
       do: assign(socket, :passphrase_form, passphrase_form(reason))

  defp decoded(socket, _p, {:error, reason}, _start) do
    socket
    |> assign(:passphrase_form, nil)
    |> put_key_error(reason)
  end

  defp put_key_error(socket, reason),
    do: update(socket, :ssh_form, &%{&1 | errors: [key_path: {ConnectError.message(reason), []}]})

  defp handle_event("change_passphrase", %{"passphrase" => params}, socket),
    do: {:halt, assign(socket, :passphrase_form, to_form(params, as: :passphrase))}

  defp handle_event("cancel_passphrase", _params, socket) do
    socket
    |> cancel_async(:key_decode)
    |> assign(:checking_passphrase?, false)
    |> assign(:passphrase_form, nil)
    |> then(&{:halt, &1})
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp check(%SshConnectionParams{auth_method: :key, key_path: path}) when is_binary(path) do
    case KeyFile.decode(path, nil) do
      {:ok, _key} -> :ok
      {:error, :key_passphrase_required} -> :ok
      error -> error
    end
  end

  defp check(%SshConnectionParams{}), do: :ok

  defp passphrase_form(reason) do
    errors =
      if reason == :key_bad_passphrase, do: [passphrase: {"Wrong passphrase", []}], else: []

    to_form(%{}, as: :passphrase, errors: errors)
  end
end
