defmodule VoyagerWeb.TracingSessionLive.Log do
  @moduledoc """
  Owns the Events card's rows, newest first: the first page, older pages, the
  live buffer and its flush, and pause/resume, with the assigns they are
  rendered from (`paused?`, `new_count`, `buffer`, `flush_scheduled?`,
  `newest_seq`, `oldest_seq`, `held_kinds`).

  Reads `id`, `mode` and `trace_session` from the socket.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import VoyagerWeb.Helpers, only: [cont: 1, halt: 1]

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias Voyager.Services.Tracer

  @row_limit 200
  @flush_ms 250

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:paused?, false)
    |> assign(:new_count, 0)
    |> assign(:buffer, [])
    |> assign(:flush_scheduled?, false)
    |> assign(:newest_seq, nil)
    |> assign(:oldest_seq, 0)
    |> assign(:held_kinds, [])
    |> stream_configure(:entries, dom_id: &entry_dom_id/1)
    |> stream(:entries, [])
    |> attach_hook(:log_timers, :handle_info, &handle_timer/2)
    |> attach_hook(:log_results, :handle_async, &handle_result/3)
  end

  @doc "Replaces the rows with the newest page and resumes the live view."
  @spec load(Socket.t()) :: Socket.t()
  def load(socket) do
    id = socket.assigns.id

    socket
    |> assign(:newest_seq, nil)
    |> assign(:paused?, false)
    |> assign(:new_count, 0)
    |> start_async(:page, fn -> Tracer.entries(id) end)
  end

  @doc "Appends the page below `oldest_seq`, pausing a running view first."
  @spec older(Socket.t()) :: Socket.t()
  def older(socket) do
    %{id: id, oldest_seq: before} = socket.assigns

    socket
    |> pause_running()
    |> start_async(:older, fn -> Tracer.entries(id, before: before) end)
  end

  @spec pause(Socket.t()) :: Socket.t()
  def pause(socket) do
    socket
    |> assign(:paused?, true)
    |> assign(:new_count, count_traces(socket.assigns.buffer))
    |> assign(:buffer, [])
  end

  @doc "Buffers broadcast entries for the next flush; while paused only counts their traces."
  @spec absorb(Socket.t(), [map()]) :: Socket.t()
  def absorb(socket, []), do: socket

  def absorb(%{assigns: %{paused?: true}} = socket, entries),
    do: update(socket, :new_count, &(&1 + count_traces(entries)))

  def absorb(socket, entries) do
    socket = update(socket, :buffer, &Enum.take(&1 ++ entries, -@row_limit))

    if socket.assigns.flush_scheduled? do
      socket
    else
      Process.send_after(self(), :flush_log, @flush_ms)
      assign(socket, :flush_scheduled?, true)
    end
  end

  @spec trace_rows([atom()]) :: non_neg_integer()
  def trace_rows(held_kinds), do: Enum.count(held_kinds, &(&1 == :trace))

  defp handle_timer(:flush_log, socket) do
    socket
    |> assign(:flush_scheduled?, false)
    |> flush()
    |> halt()
  end

  defp handle_timer(_message, socket), do: cont(socket)

  defp handle_result(:page, {:ok, {:ok, page}}, socket) do
    socket
    |> put_page(page)
    |> flush()
    |> halt()
  end

  defp handle_result(:older, {:ok, {:ok, page}}, socket) do
    socket
    |> put_older(page)
    |> halt()
  end

  defp handle_result(:page, _failed, socket) do
    socket
    |> pause()
    |> put_flash(:error, "Could not load the events.")
    |> halt()
  end

  defp handle_result(:older, _failed, socket), do: halt(socket)
  defp handle_result(_name, _result, socket), do: cont(socket)

  defp put_page(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, nil)

    # An older page still in flight was fetched below the stream this page replaces.
    socket
    |> cancel_async(:older)
    |> stream(:entries, rows, reset: true)
    |> assign(:newest_seq, newest_seq(entries))
    |> assign(:oldest_seq, oldest_seq(entries))
    |> assign(:held_kinds, kinds(rows))
  end

  defp put_older(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, socket.assigns.oldest_seq)

    socket
    |> stream(:entries, rows, at: -1)
    |> assign(:oldest_seq, oldest_seq(entries))
    |> update(:held_kinds, &(&1 ++ kinds(rows)))
  end

  defp newest_seq([]), do: -1
  defp newest_seq([%{seq: seq} | _older]), do: seq

  defp oldest_seq([]), do: 0
  defp oldest_seq(entries), do: List.last(entries).seq

  defp with_evicted(entries, false, _newer_seq), do: entries

  defp with_evicted(entries, true, newer_seq) do
    {rows, _acc} =
      Enum.flat_map_reduce(entries, newer_seq, fn
        entry, newer when is_integer(newer) and newer - entry.seq > 1 ->
          {[%{kind: :evicted, seq: entry.seq + 1}, entry], :marked}

        entry, :marked ->
          {[entry], :marked}

        entry, _newer ->
          {[entry], entry.seq}
      end)

    rows
  end

  # Until the first page lands, the buffer cannot tell which entries that page already holds.
  defp flush(%{assigns: %{paused?: false, newest_seq: newest_seq}} = socket)
       when is_integer(newest_seq) do
    case Enum.filter(socket.assigns.buffer, &(&1.seq > newest_seq)) do
      [] ->
        assign(socket, :buffer, [])

      rows ->
        newest_seq = List.last(rows).seq

        socket
        |> stream(:entries, Enum.map(rows, &Map.put(&1, :live, true)), at: 0, limit: @row_limit)
        |> assign(:buffer, [])
        |> assign(:newest_seq, newest_seq)
        |> update(:held_kinds, &Enum.take(Enum.reverse(kinds(rows)) ++ &1, @row_limit))
        |> update(:oldest_seq, &max(&1, newest_seq - @row_limit + 1))
    end
  end

  defp flush(socket), do: socket

  defp pause_running(
         %{
           assigns: %{
             mode: :active,
             paused?: false,
             trace_session: %AsyncResult{result: %{status: :running}}
           }
         } = socket
       ),
       do: pause(socket)

  defp pause_running(socket), do: socket

  defp kinds(rows), do: Enum.map(rows, & &1.kind)

  defp count_traces(entries), do: Enum.count(entries, &(&1.kind == :trace))

  defp entry_dom_id(%{kind: :evicted, seq: seq}), do: "entry-evicted-#{seq}"
  defp entry_dom_id(%{seq: seq}), do: "entry-#{seq}"
end
