defmodule VoyagerWeb.Utils.RefreshInterval do
  @moduledoc """
  Reading and writing the auto-refresh interval of a view.

  The interval lives in the `refresh` query param, so it survives page reloads
  and can be shared through a link. Values mirror the `<select>` options — the
  interval in milliseconds, or `"off"` when auto-refresh is disabled.

  Params are validated against the options a view actually offers, so a stale
  or hand-crafted URL cannot install an arbitrary timer.
  """

  alias VoyagerWeb.Utils.URL

  @param "refresh"

  @typedoc "Interval in milliseconds, or `nil` when auto-refresh is off."
  @type t :: pos_integer() | nil

  @typedoc "`{label, param value}` pairs, as passed to the interval select."
  @type options :: [{String.t(), String.t()}]

  @doc """
  Reads the interval from `handle_params/3` params, falling back to `default`
  when the param is missing or is not one of the offered `options`.
  """
  @spec from_params(map(), options(), t()) :: t()
  def from_params(params, options, default) when is_map(params) do
    from_value(Map.get(params, @param), options, default)
  end

  # Reads the interval from a single value (e.g. a `<select>` submission),
  # falling back to `default` when it is not one of the offered `options`.
  defp from_value(value, options, default) when is_list(options) do
    case parse(value, options) do
      {:ok, interval} -> interval
      :error -> default
    end
  end

  @doc """
  Renders an interval as its `refresh` param value. Also drives the `selected`
  state of the interval select, so the option and the URL cannot drift apart.
  """
  @spec to_param(t()) :: String.t()
  def to_param(nil), do: "off"
  def to_param(interval) when is_integer(interval), do: Integer.to_string(interval)

  @doc """
  Writes a submitted value into `url` as the canonical `refresh` param,
  preserving every other param. Values that are not offered are stored as
  `default`, so the URL never carries an interval a view would refuse to honour.
  """
  @spec put_param(String.t(), term(), options(), t()) :: String.t()
  def put_param(url, value, options, default) do
    param =
      value
      |> from_value(options, default)
      |> to_param()

    URL.put_query_param(url, @param, param)
  end

  # Only values a view actually offers are honoured — `"off"` included, so a
  # view without an Off option cannot have auto-refresh disabled from the URL.
  defp parse(value, options) when is_binary(value) do
    if Enum.any?(options, fn {_label, option} -> option == value end) do
      to_interval(value)
    else
      :error
    end
  end

  defp parse(_value, _options), do: :error

  defp to_interval("off"), do: {:ok, nil}

  defp to_interval(value) do
    case Integer.parse(value) do
      {interval, ""} when interval > 0 -> {:ok, interval}
      _ -> :error
    end
  end
end
