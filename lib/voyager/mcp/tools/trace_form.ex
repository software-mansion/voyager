defmodule Voyager.MCP.Tools.TraceForm do
  @moduledoc false

  alias Anubis.Server.Frame
  alias Anubis.Server.Stateless
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config

  @max_events 10_000
  @max_seconds 3_600
  @max_rate 1_000
  @function_format ~s(`function` must look like "MyApp.Repo.insert/2", "MyApp.Repo" or ":lists.map/2")
  @pids_format ~s(`pids` must be pids separated by commas, like "<0.123.0>, <0.456.0>", or empty for all processes)

  @elixir_mfa ~r/^((?:[A-Z]\w*\.)*[A-Z]\w*)(?:\.([a-z_]\w*[?!]?))?(?:\/(\d{1,3}|_))?$/
  @erlang_mfa ~r/^:?([a-z]\w*)(?:[:.]([a-z_]\w*))?(?:\/(\d{1,3}|_))?$/

  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @spec max_seconds() :: pos_integer()
  def max_seconds, do: @max_seconds

  @spec max_rate() :: pos_integer()
  def max_rate, do: @max_rate

  @spec no_forms() :: String.t()
  def no_forms,
    do: "This MCP client does not support forms (elicitation), so it cannot set up a session"

  # Only stateless-era requests (MCP 2026-07-28) can carry the form within the same tool call.
  @spec forms?(Frame.t()) :: boolean()
  def forms?(%Frame{context: context}) do
    elicitation = Map.get(context.client_capabilities || %{}, "elicitation")

    Stateless.era(context.protocol_module) == :stateless and
      (elicitation == %{} or is_map(elicitation["form"]))
  end

  @doc "Tells the user the form's answer drops the unsaved `active` session, unless it is `keep_id`."
  @spec discard_warning(map() | nil, integer() | nil) :: String.t()
  def discard_warning(active, keep_id \\ nil)

  def discard_warning(%{save: false, traces: traces, id: id}, keep_id)
      when traces > 0 and id != keep_id,
      do: " It replaces the unsaved session #{id} and discards its #{traces} events."

  def discard_warning(_active, _keep_id), do: ""

  @spec check_function(String.t() | nil) :: :ok | {:error, String.t()}
  def check_function(nil), do: :ok

  def check_function(function) do
    with {:ok, _mfa} <- parse_function(function), do: :ok
  end

  @doc """
  The form's JSON schema, prefilled with `defaults` (string keys, as the form answers).
  `save?: false` leaves out the "Save to history" toggle.
  """
  @spec schema(map(), save?: boolean()) :: map()
  def schema(defaults, opts \\ []) do
    properties = %{
      "function" =>
        property("string", defaults["function"], %{
          "title" => "Function",
          "description" => "Mod.fun/arity, Mod.fun, Mod, or :erlang_mod.fun/arity"
        }),
      "capture_args" =>
        property("boolean", defaults["capture_args"] || false, %{
          "title" => "Capture arguments",
          "description" => "Call arguments are sent to the AI"
        }),
      "return_trace" =>
        property("boolean", defaults["return_trace"], %{
          "title" => "Trace return values",
          "description" => "Return values are sent to the AI"
        }),
      "max_events" =>
        limit(
          defaults["max_events"],
          @max_events,
          "Stop after this many events (calls, returns, exceptions)"
        ),
      "max_seconds" =>
        limit(defaults["max_seconds"], @max_seconds, "Stop after this many seconds"),
      "max_rate" =>
        limit(defaults["max_rate"], @max_rate, "Stop above this many events per second"),
      "pids" =>
        property("string", defaults["pids"], %{
          "title" => "Processes",
          "description" => "Comma-separated pids like <0.123.0>; empty traces all processes"
        }),
      "new_processes_only" =>
        property("boolean", defaults["new_processes_only"] || false, %{
          "title" => "New processes only",
          "description" => "With no pids, trace only processes spawned after the start"
        }),
      "scope" =>
        property("string", defaults["scope"] || "global", %{
          "title" => "Scope",
          "enum" => ["global", "local"],
          "description" =>
            "global sees calls from other modules to exported functions; local also sees calls within the module and private functions"
        })
    }

    properties =
      if Keyword.get(opts, :save?, true),
        do:
          Map.put(
            properties,
            "save",
            property("boolean", defaults["save"] || false, %{
              "title" => "Save to history",
              "description" =>
                "Keep every event in Voyager; an unsaved session keeps only its newest #{Tracer.kept_traces()} and is replaced by the next one"
            })
          ),
        else: properties

    %{"type" => "object", "properties" => properties, "required" => ["function"]}
  end

  @doc "The form defaults of `config`, so a reconfigure starts from what the session traces."
  @spec defaults(Config.t()) :: map()
  def defaults(%Config{} = config) do
    %{
      "function" => function_name(config),
      "capture_args" => config.capture == :args,
      "return_trace" => config.return_trace,
      "max_events" => config.max_events && min(config.max_events, @max_events),
      "max_seconds" => config.max_time_ms && to_seconds(config.max_time_ms),
      "max_rate" => config.max_rate && min(config.max_rate, @max_rate),
      "pids" => if(config.processes == :pids, do: Enum.join(config.pids, ", ")),
      "new_processes_only" => config.processes == :new,
      "scope" => Atom.to_string(config.scope)
    }
  end

  # Written the way `parse_function/1` reads it back, so an unchanged form keeps the target.
  defp function_name(%Config{} = config) do
    module =
      case config.module do
        "Elixir." <> module -> module
        module -> ":" <> module
      end

    case {config.function, config.arity} do
      {"_", _arity} -> module
      {function, nil} -> "#{module}.#{function}"
      {function, arity} -> "#{module}.#{function}/#{arity}"
    end
  end

  @doc """
  The `Config` attrs of an accepted form, validated with the form's caps. What the form cannot
  show (`budget`, `:existing` processes, a `max_time_ms` in part seconds) keeps `current`'s value
  while its field is left as `defaults/1` prefilled it.
  """
  @spec config_attrs(term(), Config.t()) ::
          {:ok, map()} | {:error, String.t() | Ecto.Changeset.t()}
  def config_attrs(content, current \\ %Config{})

  def config_attrs(content, current) when is_map(content) do
    new_only? = content["new_processes_only"] == true

    with {:ok, mfa} <- parse_function(content["function"]),
         {:ok, processes} <- processes(content["pids"], new_only?, current) do
      attrs =
        mfa
        |> Map.merge(processes)
        |> Map.merge(%{
          "budget" => current.budget,
          "capture" => if(content["capture_args"] == true, do: "args", else: "arity"),
          "return_trace" => content["return_trace"] == true,
          "scope" => content["scope"] || "global",
          "max_events" => content["max_events"],
          "max_rate" => content["max_rate"],
          "max_time_ms" => max_time_ms(content["max_seconds"], current.max_time_ms)
        })

      with {:ok, _config} <- validate(attrs), do: {:ok, attrs}
    end
  end

  def config_attrs(_content, _current), do: {:error, "The form's answer is not an object"}

  @spec format_errors(Ecto.Changeset.t()) :: String.t()
  def format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp validate(attrs) do
    attrs
    |> Config.changeset()
    |> Ecto.Changeset.validate_number(:max_events, less_than_or_equal_to: @max_events)
    |> Ecto.Changeset.validate_number(:max_rate, less_than_or_equal_to: @max_rate)
    |> Ecto.Changeset.apply_action(:validate)
  end

  defp limit(default, max, title),
    do: property("integer", default, %{"title" => title, "minimum" => 1, "maximum" => max})

  defp property(type, nil, fields), do: Map.put(fields, "type", type)

  defp property(type, default, fields),
    do: Map.merge(fields, %{"type" => type, "default" => default})

  defp to_ms(seconds) when is_integer(seconds), do: seconds * 1_000

  defp to_ms(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} -> seconds * 1_000
      _invalid -> seconds
    end
  end

  defp to_ms(other), do: other

  defp to_seconds(ms), do: div(ms + 999, 1_000)

  defp max_time_ms(seconds, current_ms) do
    ms = to_ms(seconds)
    if current_ms && ms == to_seconds(current_ms) * 1_000, do: current_ms, else: ms
  end

  defp processes(text, new_only?, current) when is_binary(text) do
    pids = text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      pids != [] -> {:ok, %{"processes" => "pids", "pids" => pids}}
      String.trim(text) == "" -> processes(nil, new_only?, current)
      true -> {:error, @pids_format}
    end
  end

  defp processes(nil, true, _current), do: {:ok, %{"processes" => "new"}}

  defp processes(nil, false, %Config{processes: :existing}),
    do: {:ok, %{"processes" => "existing"}}

  defp processes(nil, false, _current), do: {:ok, %{"processes" => "all"}}
  defp processes(_pids, _new_only?, _current), do: {:error, @pids_format}

  defp parse_function(function) when is_binary(function) do
    function = String.trim(function)

    cond do
      match = Regex.run(@elixir_mfa, function, capture: :all_but_first) ->
        [module | rest] = match
        {:ok, mfa_attrs(["Elixir." <> String.replace_prefix(module, "Elixir.", "") | rest])}

      match = Regex.run(@erlang_mfa, function, capture: :all_but_first) ->
        {:ok, mfa_attrs(match)}

      true ->
        {:error, @function_format}
    end
  end

  defp parse_function(_function), do: {:error, @function_format}

  # `Regex.run/3` drops unmatched trailing groups and returns "" for unmatched inner ones.
  defp mfa_attrs([module | rest]) do
    [function, arity] = Enum.take(rest ++ ["", ""], 2)

    %{
      "module" => module,
      "function" => if(function == "", do: "_", else: function),
      "arity" => if(arity in ["", "_"], do: nil, else: String.to_integer(arity))
    }
  end
end
