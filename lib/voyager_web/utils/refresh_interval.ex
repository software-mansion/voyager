defmodule VoyagerWeb.Utils.RefreshInterval do
  @moduledoc """
  Reading and writing the auto-refresh interval of a view.

  The interval lives in the `refresh` query param, so it survives page reloads
  and can be shared through a link. Values mirror the `<select>` options — the
  interval in milliseconds, or `"off"` when auto-refresh is disabled.

  Params are validated against the options a view actually offers, so a stale
  or hand-crafted URL cannot install an arbitrary timer.
  """

  @param "refresh"

  @typedoc "Interval in milliseconds, or `nil` when auto-refresh is off."
  @type t :: pos_integer() | nil

  @typedoc "`{label, param value}` pairs, as passed to the interval select."
  @type options :: [{String.t(), String.t()}]

  @spec param() :: String.t()
  def param, do: @param

  @doc """
  Reads the interval from `handle_params/3` params, falling back to `default`
  when the param is missing or is not one of the offered `options`.
  """
  @spec from_params(map(), options(), t()) :: t()
  def from_params(params, options, default) when is_map(params) do
    from_value(Map.get(params, @param), options, default)
  end

  @doc """
  Reads the interval from a single value (e.g. a `<select>` submission),
  falling back to `default` when it is not one of the offered `options`.
  """
  @spec from_value(term(), options(), t()) :: t()
  def from_value(value, options, default) when is_list(options) do
    case parse(value, options) do
      {:ok, interval} -> interval
      :error -> default
    end
  end

  @doc """
  Renders an interval as its `refresh` param value.
  """
  @spec to_param(t()) :: String.t()
  def to_param(nil), do: "off"
  def to_param(interval) when is_integer(interval), do: Integer.to_string(interval)

  defp parse("off", _options), do: {:ok, nil}

  defp parse(value, options) when is_binary(value) do
    with true <- Enum.any?(options, fn {_label, option} -> option == value end),
         {interval, ""} when interval > 0 <- Integer.parse(value) do
      {:ok, interval}
    else
      _ -> :error
    end
  end

  defp parse(_value, _options), do: :error
end
