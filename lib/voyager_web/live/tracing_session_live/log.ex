defmodule VoyagerWeb.TracingSessionLive.Log do
  @moduledoc """
  Owns the Events card's rows, newest first: the first page, older pages, the
  live buffer and its flush, pause/resume and search mode, with the assigns
  they are rendered from (`paused?`, `new_count`, `buffer`, `flush_scheduled?`,
  `newest_seq`, `oldest_seq`, `held_kinds`, `search`, `search_form`).

  Reads `id`, `mode` and `trace_session` from the socket.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import VoyagerWeb.Helpers, only: [cont: 1, halt: 1]

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias Voyager.Services.Tracer

  @row_limit 200
  @search_limit 100
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
    |> assign(:search, nil)
    |> assign(:search_form, to_form(%{}, as: :search))
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
    |> cancel_async(:search)
    |> assign(:search, nil)
    |> assign(:search_form, to_form(%{}, as: :search))
    |> assign(:newest_seq, nil)
    |> assign(:paused?, false)
    |> assign(:new_count, 0)
    |> start_async(:page, fn -> Tracer.entries(id) end)
  end

  @doc "Appends the page below `oldest_seq`, pausing a running view first; the next match page while searching."
  @spec older(Socket.t()) :: Socket.t()
  def older(%{assigns: %{search: %{}}} = socket), do: start_search(socket)

  def older(socket) do
    %{id: id, oldest_seq: before} = socket.assigns

    socket
    |> pause_running()
    |> start_async(:older, fn -> Tracer.entries(id, before: before) end)
  end

  @doc "Starts a search for the form's query; a blank query returns to the live list."
  @spec search(Socket.t(), map()) :: Socket.t()
  def search(socket, %{"query" => query} = params) do
    socket = assign(socket, :search_form, to_form(params, as: :search))

    case String.trim(query) do
      "" when is_nil(socket.assigns.search) ->
        socket

      "" ->
        load(socket)

      query ->
        socket
        |> assign(:search, %{query: query, total: nil, shown: 0, oldest_seq: nil, traces: nil})
        |> start_search()
    end
  end

  @spec pause(Socket.t()) :: Socket.t()
  def pause(socket) do
    socket
    |> assign(:paused?, true)
    |> assign(:new_count, count_traces(socket.assigns.buffer))
    |> assign(:buffer, [])
  end

  @doc "Buffers broadcast entries for the next flush; counts their traces while paused, drops them while searching."
  @spec absorb(Socket.t(), [map()]) :: Socket.t()
  def absorb(socket, []), do: socket

  def absorb(%{assigns: %{search: %{}}} = socket, _entries), do: socket

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

  @spec trace_rows(map()) :: non_neg_integer()
  def trace_rows(%{held_kinds: held_kinds}), do: Enum.count(held_kinds, &(&1 == :trace))

  defp handle_timer(:flush_log, socket) do
    socket
    |> assign(:flush_scheduled?, false)
    |> flush()
    |> halt()
  end

  defp handle_timer(_message, socket), do: cont(socket)

  defp handle_result(name, _result, %{assigns: %{search: %{}}} = socket)
       when name in [:page, :older],
       do: halt(socket)

  # A failed session reload leaves no traces to scope the matches; the next load resets the search.
  defp handle_result(
         :search,
         _result,
         %{assigns: %{trace_session: %AsyncResult{result: nil}}} = socket
       ),
       do: halt(socket)

  defp handle_result(:search, {:ok, {:ok, page}}, %{assigns: %{search: %{}}} = socket) do
    socket
    |> put_matches(page)
    |> halt()
  end

  defp handle_result(:search, {:ok, {:error, reason}}, %{assigns: %{search: %{}}} = socket) do
    socket
    |> fail_search(reason)
    |> halt()
  end

  defp handle_result(:search, {:exit, _reason}, %{assigns: %{search: %{}}} = socket) do
    socket
    |> fail_search(:exit)
    |> halt()
  end

  defp handle_result(:search, _stale, socket), do: halt(socket)

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

  defp start_search(%{assigns: %{id: id, search: %{query: query, oldest_seq: before}}} = socket) do
    opts = [limit: @search_limit] ++ if(before, do: [before: before], else: [])

    socket
    |> cancel_async(:search)
    |> start_async(:search, fn -> Tracer.search(id, query, opts) end)
  end

  defp put_matches(%{assigns: %{search: search}} = socket, %{entries: entries, total: total}) do
    first? = is_nil(search.total)
    shown = if(first?, do: 0, else: search.shown) + length(entries)

    # Later pages recount matches newer than the first page, which paging by `before` never reaches.
    total =
      cond do
        length(entries) < @search_limit -> shown
        first? -> total
        true -> search.total
      end

    socket
    |> stream(:entries, entries, if(first?, do: [reset: true], else: [at: -1]))
    |> assign(:search, %{
      search
      | total: total,
        shown: shown,
        oldest_seq: List.last(entries, %{seq: search.oldest_seq}).seq,
        traces: search.traces || socket.assigns.trace_session.result.traces
    })
  end

  defp fail_search(%{assigns: %{search: %{total: nil}}} = socket, reason) do
    socket
    |> load()
    |> put_flash(:error, search_error(reason))
  end

  defp fail_search(socket, reason), do: put_flash(socket, :error, search_error(reason))

  defp search_error(:not_found), do: "No such tracing session."
  defp search_error(:exit), do: "The tracer did not respond. Try again."
  defp search_error(reason), do: "Tracing failed: #{inspect(reason)}"

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
  defp flush(%{assigns: %{paused?: false, search: nil, newest_seq: newest_seq}} = socket)
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
