defmodule VoyagerWeb.ConnectLive.SshConfigImport do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.Socket
  alias Voyager.NodeSession.ConnectError
  alias Voyager.Services.SSH.Config
  alias Voyager.Settings
  alias VoyagerWeb.ConnectLive.KeyAuth
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:ssh_config_modal?, false)
    |> assign(:ssh_config_form, path_form(""))
    |> assign(:ssh_config_hosts, nil)
    |> assign(:ssh_config_unsupported, [])
    |> attach_hook(:ssh_config_import, :handle_event, &handle_event/3)
  end

  @spec selected_host([Config.host()] | nil, Form.t()) :: Config.host() | nil
  def selected_host(hosts, form) do
    current =
      {to_string(form[:ssh_host].value), to_string(form[:ssh_user].value),
       to_string(form[:ssh_port].value)}

    Enum.find(List.wrap(hosts), fn host ->
      params = SshConnectionParams.params_from_host(host)
      {params["ssh_host"], params["ssh_user"], params["ssh_port"]} == current
    end)
  end

  defp handle_event("open_ssh_config", _params, socket) do
    socket = assign(socket, :ssh_config_modal?, true)
    saved_path = Settings.get(:ssh_config_path)

    if is_nil(socket.assigns.ssh_config_hosts) and not is_nil(saved_path) do
      {:halt, load(socket, saved_path)}
    else
      {:halt, socket}
    end
  end

  defp handle_event("close_ssh_config", _params, socket),
    do: {:halt, assign(socket, :ssh_config_modal?, false)}

  defp handle_event("change_ssh_config_path", %{"ssh_config" => %{"path" => path}}, socket),
    do: {:halt, assign(socket, :ssh_config_form, path_form(path))}

  defp handle_event("edit_ssh_config_path", _params, socket),
    do: {:halt, assign(socket, :ssh_config_hosts, nil)}

  defp handle_event("import_ssh_config", %{"ssh_config" => %{"path" => path}}, socket),
    do: {:halt, load(socket, path)}

  defp handle_event("reload_ssh_config", _params, socket),
    do: {:halt, load(socket, socket.assigns.ssh_config_form[:path].value)}

  defp handle_event("fill_ssh_host", %{"alias" => host_alias}, socket) do
    host = Enum.find(socket.assigns.ssh_config_hosts, &(&1.alias == host_alias))

    form =
      socket.assigns.ssh_form.params
      |> Map.merge(SshConnectionParams.params_from_host(host))
      |> Map.put("password", "")
      |> SshConnectionParams.changeset()
      |> KeyAuth.checked_form()

    socket =
      socket
      |> assign(:ssh_form, form)
      |> assign(:ssh_config_modal?, false)
      |> update(:show_ssh_advanced, &(&1 or advanced_value?(host)))

    {:halt, socket}
  end

  defp handle_event("remove_ssh_host", %{"alias" => host_alias}, socket) do
    hosts = Enum.reject(socket.assigns.ssh_config_hosts, &(&1.alias == host_alias))
    {:halt, assign(socket, :ssh_config_hosts, hosts)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp load(socket, path) do
    case read(path) do
      {:ok, %{hosts: hosts, unsupported: unsupported}} ->
        Settings.put(:ssh_config_path, path)

        socket
        |> assign(:ssh_config_form, path_form(path))
        |> assign(:ssh_config_hosts, hosts)
        |> assign(:ssh_config_unsupported, unsupported)

      {:error, reason} ->
        socket
        |> assign(:ssh_config_form, path_form(path, path: {ConnectError.message(reason), []}))
        |> assign(:ssh_config_hosts, nil)
    end
  end

  defp read(""), do: Config.read()
  defp read(path), do: Config.read(path)

  defp advanced_value?(host), do: host.port not in [nil, 22] or is_binary(host.identity_agent)

  defp path_form(path, errors \\ []),
    do: to_form(%{"path" => path}, as: :ssh_config, errors: errors)
end
