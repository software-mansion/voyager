defmodule VoyagerWeb.FormSchemas.TraceConfigParams do
  @moduledoc """
  The session parameters form: time in seconds and pids as one text. It holds no tracing
  rules of its own; `Voyager.Services.Tracer.Config` validates, and its errors land on the
  form's fields.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Voyager.Services.Tracer.Config

  @fields [
    :module,
    :function,
    :arity,
    :processes,
    :pids,
    :capture,
    :scope,
    :return_trace,
    :budget,
    :max_events,
    :max_rate,
    :max_seconds
  ]

  @primary_key false
  embedded_schema do
    field :module, :string
    field :function, :string
    field :arity, :integer
    field :processes, Ecto.Enum, values: Ecto.Enum.values(Config, :processes)
    field :pids, :string
    field :capture, Ecto.Enum, values: Ecto.Enum.values(Config, :capture)
    field :scope, Ecto.Enum, values: Ecto.Enum.values(Config, :scope)
    field :return_trace, :boolean
    field :budget, :integer
    field :max_events, :integer
    field :max_rate, :integer
    field :max_seconds, :integer
  end

  @type t :: %__MODULE__{}

  @doc "The form for `config`, or a new session's defaults for `nil`."
  @spec from_config(Config.t() | nil) :: t()
  # No schema defaults: `cast/4` turns a cleared input into the field's default.
  def from_config(nil),
    do:
      from_config(%Config{
        processes: :all,
        max_events: 10_000,
        max_rate: 1_000,
        max_time_ms: 300_000
      })

  def from_config(%Config{} = config) do
    %__MODULE__{
      module: typed_module(config.module),
      function: if(config.function != "_", do: config.function),
      arity: config.arity,
      processes: config.processes,
      pids: Enum.join(config.pids, ", "),
      capture: config.capture,
      scope: config.scope,
      return_trace: config.return_trace,
      budget: config.budget,
      max_events: config.max_events,
      max_rate: config.max_rate,
      max_seconds: config.max_time_ms && div(config.max_time_ms, 1_000)
    }
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = params, attrs) do
    params
    |> cast(attrs, @fields)
    |> validate_change(:module, fn :module, module ->
      if Config.module_name(module),
        do: [],
        else: [module: "must look like MyApp.Repo or :lists"]
    end)
    |> validate_config()
  end

  @doc "The config a valid form describes."
  @spec to_config(t()) :: Config.t()
  def to_config(%__MODULE__{} = params) do
    params
    |> config_attrs()
    |> Config.changeset()
    |> apply_changes()
  end

  defp validate_config(changeset) do
    config = changeset |> apply_changes() |> config_attrs() |> Config.changeset()
    Enum.reduce(config.errors, changeset, &copy_error/2)
  end

  # A field that already failed to cast or parse would get a second, misleading error.
  defp copy_error({field, error}, changeset) do
    {field, {message, opts}} = form_error(field, error)

    if Keyword.has_key?(changeset.errors, field),
      do: changeset,
      else: add_error(changeset, field, message, opts)
  end

  defp form_error(:max_time_ms, {message, opts}) do
    opts = if opts[:number], do: Keyword.put(opts, :number, div(opts[:number], 1_000)), else: opts
    {:max_seconds, {message, opts}}
  end

  defp form_error(field, error), do: {field, error}

  defp typed_module(nil), do: nil
  defp typed_module("Elixir." <> elixir), do: elixir
  defp typed_module(erlang), do: ":" <> erlang

  defp config_attrs(%__MODULE__{} = params) do
    %{
      module: params.module && Config.module_name(params.module),
      function: params.function || "_",
      arity: params.arity,
      processes: params.processes,
      pids: pids(params),
      capture: params.capture,
      scope: params.scope,
      return_trace: params.return_trace,
      budget: params.budget,
      max_events: params.max_events,
      max_rate: params.max_rate,
      max_time_ms: params.max_seconds && params.max_seconds * 1_000
    }
  end

  # The hidden pids input keeps its text for another process set; the config must not.
  defp pids(%__MODULE__{processes: :pids, pids: pids}),
    do: String.split(pids || "", ~r/[\s,]+/, trim: true)

  defp pids(_params), do: []
end
