defmodule VoyagerWeb.SettingsLive.TracingSettings do
  @moduledoc false
  use VoyagerWeb, :live_component

  alias Voyager.Services.Tracer
  alias VoyagerWeb.FormSchemas.TraceStorageParams
  alias VoyagerWeb.SettingsComponents

  @impl true
  def mount(socket) do
    socket
    |> assign(:locked?, Tracer.storage_limit_locked?())
    |> assign(:form, storage_form())
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border-base-200 border shadow-sm">
      <div class="card-body gap-4 p-5">
        <div>
          <h3 class="text-base-content text-sm font-semibold">Tracing</h3>
          <p class="text-base-content/70 mt-1 text-sm">
            Saved tracing sessions share this much disk space. A run stops once it is used up.
          </p>
        </div>

        <SettingsComponents.locked_alert id="trace-storage-locked" locked?={@locked?} />

        <.form
          for={@form}
          id="trace-storage-form"
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="flex items-end justify-between gap-2"
        >
          <div class="flex-1">
            <div class="mb-1.5 flex items-center gap-2">
              <label
                class="font-mono tracking-label text-base-content/70 flex items-center gap-0.5 text-xs font-semibold uppercase"
                for={@form[:limit_mb].id}
              >
                Storage limit (MB)
              </label>
            </div>
            <.input
              field={@form[:limit_mb]}
              type="number"
              min="1"
              disabled={@locked?}
              phx-mounted={@focus? && JS.focus()}
              float_errors
              class="font-mono flex-1 text-sm"
            />
          </div>

          <div class="card-actions justify-end">
            <button type="submit" class="btn btn-primary" disabled={@locked?}>
              Save limit
            </button>
          </div>
        </.form>
        <p class="text-base-content/70 mt-3 text-xs">
          Lowering it deletes no saved session. A running one stops once it passes the new limit.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"trace_storage" => params}, socket) do
    form =
      params
      |> TraceStorageParams.changeset()
      |> to_form(as: :trace_storage, action: :validate)

    socket
    |> assign(:form, form)
    |> noreply()
  end

  def handle_event("save", %{"trace_storage" => params}, socket) do
    changeset = TraceStorageParams.changeset(params)

    with {:ok, %TraceStorageParams{limit_mb: mb}} <-
           Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- Tracer.put_storage_limit_mb(mb) do
      socket
      |> push_flash(:info, "Storage limit saved")
      |> noreply()
    else
      {:error, %Ecto.Changeset{data: %TraceStorageParams{}} = changeset} ->
        socket
        |> assign(:form, to_form(changeset, as: :trace_storage))
        |> noreply()

      {:error, _locked_or_invalid} ->
        socket
        |> push_flash(:error, "Could not save the storage limit")
        |> assign(locked?: Tracer.storage_limit_locked?(), form: storage_form())
        |> noreply()
    end
  end

  defp storage_form do
    %{"limit_mb" => Tracer.storage_limit_mb()}
    |> TraceStorageParams.changeset()
    |> to_form(as: :trace_storage)
  end
end
