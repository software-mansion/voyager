defmodule Voyager.Services.Tracer.Config do
  @moduledoc """
  A tracing session's parameters, validated before they reach the agent so the
  UI and MCP can report errors per field. The agent still validates on start.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Voyager.Services.Tracer.Refusals

  @limits [:max_events, :max_rate, :max_time_ms]
  @max_time_ms 3_600_000
  @max_budget 100_000
  @max_pids 100

  @primary_key false
  embedded_schema do
    field :module, :string
    field :function, :string, default: "_"
    field :arity, :integer
    field :processes, Ecto.Enum, values: [:all, :existing, :new, :pids], default: :pids
    field :pids, {:array, :string}, default: []
    field :capture, Ecto.Enum, values: [:arity, :args], default: :arity
    field :scope, Ecto.Enum, values: [:local, :global], default: :global
    field :return_trace, :boolean, default: false
    field :budget, :integer, default: Voyager.Agent.default_budget()
    field :max_events, :integer
    field :max_rate, :integer
    field :max_time_ms, :integer
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:module, :function, :processes, :capture, :scope, :budget])
    |> validate_length(:module, max: 255)
    |> validate_length(:function, max: 255)
    |> validate_exclusion(:module, ["_"], message: "cannot be a wildcard")
    |> validate_number(:arity, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
    |> validate_number(:budget, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_budget)
    |> validate_number(:max_events, greater_than: 0)
    |> validate_number(:max_rate, greater_than: 0)
    |> validate_number(:max_time_ms, greater_than: 0, less_than_or_equal_to: @max_time_ms)
    |> validate_wildcard_arity()
    |> validate_limits()
    |> validate_pids()
    |> validate_module_allowed()
  end

  @doc "The `{spec, limits}` pair `trace_start` takes on the agent; `pids` are the resolved `:pids`."
  @spec to_agent(t(), [pid()]) :: {map(), map()}
  def to_agent(%__MODULE__{} = config, pids) do
    spec = %{
      module: config.module,
      function: if(config.function == "_", do: :_, else: config.function),
      arity: config.arity || :_,
      processes: if(config.processes == :pids, do: pids, else: config.processes),
      capture: config.capture,
      scope: config.scope,
      return_trace: config.return_trace,
      match_spec: :undefined
    }

    limits =
      config
      |> Map.take([:budget | @limits])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    {spec, limits}
  end

  # `trace:function/4` takes '_' only in the rightmost fields.
  defp validate_wildcard_arity(changeset) do
    if get_field(changeset, :function) == "_" and get_field(changeset, :arity) != nil do
      add_error(changeset, :arity, "must be empty when the function is a wildcard")
    else
      changeset
    end
  end

  defp validate_limits(changeset) do
    if Enum.any?(@limits, &get_field(changeset, &1)) do
      changeset
    else
      add_error(changeset, :max_events, "set at least one of max events, max rate or max time")
    end
  end

  defp validate_pids(changeset) do
    pids = get_field(changeset, :pids)

    cond do
      get_field(changeset, :processes) != :pids ->
        changeset

      pids == [] ->
        add_error(changeset, :pids, "can't be blank")

      length(pids) > @max_pids ->
        add_error(changeset, :pids, "at most #{@max_pids} pids")

      not Enum.all?(pids, &pid_string?/1) ->
        add_error(changeset, :pids, "must be pids like <123.45.0>")

      true ->
        changeset
    end
  end

  defp validate_module_allowed(changeset) do
    module = get_field(changeset, :module)

    cond do
      is_nil(module) ->
        changeset

      module == Atom.to_string(Voyager.Agent.module()) or Refusals.always_refused?(module) ->
        add_error(changeset, :module, "cannot be traced")

      get_field(changeset, :processes) == :pids ->
        changeset

      Refusals.hot?(module) ->
        add_error(changeset, :module, "is too hot to trace on all processes, select pids")

      true ->
        changeset
    end
  end

  defp pid_string?(pid), do: is_binary(pid) and Voyager.Pid.parse(pid) != nil
end
