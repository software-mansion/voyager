defmodule VoyagerWeb.Formatters do
  @moduledoc """
  Generic value formatters for display in templates — byte sizes, large
  counts, integers, durations, booleans, and timestamps.

  These are presentation helpers with no domain knowledge, intended to be
  reused across LiveViews and components (imported via `VoyagerWeb`).
  """

  @kib 1_024
  @mib 1_048_576
  @gib 1_073_741_824
  @tib 1_099_511_627_776

  @type duration_parts_result ::
          {year :: non_neg_integer(), day :: non_neg_integer(), hour :: non_neg_integer(),
           minute :: non_neg_integer(), second :: non_neg_integer()}

  @doc """
  Splits a byte count into a `{value, unit}` tuple, picking the largest unit
  that keeps the value readable.

      iex> VoyagerWeb.Formatters.byte_parts(1_572_864)
      {2, "MB"}
  """
  @spec byte_parts(non_neg_integer()) :: {number(), String.t()}
  def byte_parts(bytes) when bytes >= @tib, do: {Float.round(bytes / @tib, 1), "TB"}
  def byte_parts(bytes) when bytes >= @gib, do: {Float.round(bytes / @gib, 1), "GB"}
  def byte_parts(bytes) when bytes >= @mib, do: {round(bytes / @mib), "MB"}
  def byte_parts(bytes) when bytes >= @kib, do: {round(bytes / @kib), "KB"}
  def byte_parts(bytes), do: {bytes, "B"}

  @doc """
  Formats a byte count as a human-readable string, e.g. `"4.2 GB"`.
  Returns `"—"` for `nil`.
  """
  @spec format_bytes(non_neg_integer() | nil) :: String.t()
  def format_bytes(nil), do: "—"

  def format_bytes(bytes) do
    {value, unit} = byte_parts(bytes)
    "#{value} #{unit}"
  end

  @doc """
  Formats a byte count as a compact string with no space, e.g. `"4.2GB"`.
  """
  @spec format_bytes_compact(non_neg_integer()) :: String.t()
  def format_bytes_compact(bytes) do
    {value, unit} = byte_parts(bytes)
    "#{value}#{unit}"
  end

  @doc """
  Splits a large count into an abbreviated `{value, unit}` tuple.

  Billions use `"B"`, values over ten million use `"M"`; smaller counts are
  returned as a thousands-separated string with a `nil` unit.

      iex> VoyagerWeb.Formatters.count_parts(2_500_000_000)
      {2.5, "B"}
      iex> VoyagerWeb.Formatters.count_parts(1_234)
      {"1,234", nil}
  """
  @spec count_parts(non_neg_integer()) :: {number(), String.t()} | {String.t(), nil}
  def count_parts(n) when n >= 1_000_000_000, do: {Float.round(n / 1_000_000_000, 1), "B"}
  def count_parts(n) when n >= 10_000_000, do: {Float.round(n / 1_000_000, 1), "M"}
  def count_parts(n), do: {format_integer(n), nil}

  @doc """
  Formats a large count as a compact string with no space, e.g. `"2.5B"` or `"1,234"`.
  """
  @spec format_count_compact(non_neg_integer()) :: String.t()
  def format_count_compact(n) do
    {value, unit} = count_parts(n)
    "#{value}#{unit}"
  end

  @doc """
  Formats an integer with thousands separators, e.g. `"1,234,567"`.
  """
  @spec format_integer(integer()) :: String.t()
  def format_integer(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Formats a `DateTime` as a `HH:MM:SS` clock string.
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  @doc """
  Breaks a duration in milliseconds into `{years, days, hours, minutes, seconds}`.
  """
  @spec duration_parts(non_neg_integer()) :: duration_parts_result()
  def duration_parts(ms) when is_integer(ms) do
    total_seconds = div(ms, 1_000)
    years = div(total_seconds, 31_536_000)
    days = total_seconds |> rem(31_536_000) |> div(86_400)
    hours = total_seconds |> rem(86_400) |> div(3_600)
    minutes = total_seconds |> rem(3_600) |> div(60)
    seconds = rem(total_seconds, 60)
    {years, days, hours, minutes, seconds}
  end

  @doc """
  Formats a duration in milliseconds as a compact uptime label, picking the
  largest meaningful unit, e.g. `"2yr 5d"`, `"3d 4h"`, `"2m"`, `"42s"`.
  """
  @spec format_uptime(non_neg_integer()) :: String.t()
  def format_uptime(ms) when is_integer(ms) do
    {years, days, hours, minutes, seconds} = duration_parts(ms)

    cond do
      years > 0 -> "#{years}yr #{days}d"
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{seconds}s"
    end
  end
end
