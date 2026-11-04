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

  require Logger

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:ssh_config_modal?, false)
    |> assign(:ssh_config_form, path_form(""))
    |> assign(:ssh_config_hosts, nil)
    |> assign(:ssh_config_unsupported, [])
    |> assign(:ssh_config_picked_alias, nil)
    |> attach_hook(:ssh_config_import, :handle_event, &handle_event/3)
  end

  @spec config_path(String.t()) :: Path.t()
  def config_path(""), do: "~/.ssh/config"
  def config_path(path), do: path

  @spec selected_host([Config.host()] | nil, Form.t(), String.t() | nil) :: Config.host() | nil
  def selected_host(hosts, form, picked_alias \\ nil) do
    current =
      {to_string(form[:ssh_host].value), to_string(form[:ssh_user].value),
       to_string(form[:ssh_port].value)}

    matching =
      hosts
      |> List.wrap()
      |> Enum.filter(fn host ->
        params = SshConnectionParams.params_from_host(host)
        {params["ssh_host"], params["ssh_user"], params["ssh_port"]} == current
      end)

    Enum.find(matching, List.first(matching), &(&1.alias == picked_alias))
  end

  defp handle_event("open_ssh_config", _params, socket) do
    socket = assign(socket, :ssh_config_modal?, true)
    saved_path = Settings.get(:ssh_config_path)

    if load_saved_path?(socket.assigns, saved_path) do
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
    case Enum.find(List.wrap(socket.assigns.ssh_config_hosts), &(&1.alias == host_alias)) do
      nil -> {:halt, socket}
      host -> {:halt, fill_host(socket, host)}
    end
  end

  defp handle_event("remove_ssh_host", _params, %{assigns: %{ssh_config_hosts: nil}} = socket),
    do: {:halt, socket}

  defp handle_event("remove_ssh_host", %{"alias" => host_alias}, socket) do
    hosts = Enum.reject(socket.assigns.ssh_config_hosts, &(&1.alias == host_alias))
    {:halt, assign(socket, :ssh_config_hosts, hosts)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp load_saved_path?(%{ssh_config_hosts: nil, ssh_config_form: form}, saved_path)
       when is_binary(saved_path),
       do: form[:path].value in ["", saved_path]

  defp load_saved_path?(_assigns, _saved_path), do: false

  defp fill_host(socket, host) do
    form =
      socket.assigns.ssh_form.params
      |> Map.merge(SshConnectionParams.params_from_host(host))
      |> Map.put("password", "")
      |> SshConnectionParams.changeset()
      |> KeyAuth.checked_form()

    socket
    |> assign(:ssh_form, form)
    |> assign(:ssh_config_picked_alias, host.alias)
    |> assign(:ssh_config_modal?, false)
    |> update(:show_ssh_advanced, &(&1 or advanced_value?(host)))
  end

  defp load(socket, path) do
    case path |> config_path() |> Config.read() do
      {:ok, %{hosts: hosts, unsupported: unsupported}} ->
        remember_path(path)

        Voyager.Telemetry.dispatch!("voyager.ssh_config.import",
          measurements: %{hosts: length(hosts), unsupported: length(unsupported)},
          metadata: %{keywords: Enum.map(unsupported, & &1.keyword)}
        )

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

  defp remember_path(path) do
    case Settings.put(:ssh_config_path, path) do
      {:ok, _setting} -> :ok
      {:error, reason} -> Logger.warning("Failed to persist ssh_config_path: #{inspect(reason)}")
    end
  end

  defp advanced_value?(host), do: host.port not in [nil, 22] or is_binary(host.identity_agent)

  defp path_form(path, errors \\ []),
    do: to_form(%{"path" => path}, as: :ssh_config, errors: errors)
end
