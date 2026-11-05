defmodule VoyagerWeb.TracingSessionLive.Log do
  @moduledoc """
  Owns the Events card's rows, newest first: the first page, older pages, the
  live buffer and its flush, pause/resume and search mode, with the assigns
  they are rendered from (`paused?`, `new_count`, `pending_count`, `buffer`,
  `awaiting_ack?`, `newest_seq`, `oldest_seq`, `held`, `search`, `search_form`).

  The view calls `flush/1` on its own tick. A flush that streams rows pushes
  `"log-flushed"` and the next one waits for `ack/1`, so a browser that falls
  behind gets fewer flushes, not a growing socket queue.

  Reads `id`, `mode` and `trace_session` from the socket.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import VoyagerWeb.Helpers, only: [cont: 1, halt: 1]

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias Voyager.Services.Tracer

  @row_limit 200
  @flush_limit 50
  @search_limit 100

  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:paused?, false)
    |> assign(:new_count, 0)
    |> assign(:pending_count, 0)
    |> assign(:buffer, [])
    |> assign(:awaiting_ack?, false)
    |> assign(:newest_seq, nil)
    |> assign(:oldest_seq, 0)
    |> assign(:held, [])
    |> assign(:search, nil)
    |> assign(:search_form, to_form(%{}, as: :search))
    |> stream_configure(:entries, dom_id: &entry_dom_id/1)
    |> stream(:entries, [])
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
    |> assign(:pending_count, 0)
    # An ack lost with an unmounted card would otherwise hold the log forever.
    |> assign(:awaiting_ack?, false)
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

  @doc "Freezes the rows; ignored while a reload is replacing them, as its page would unfreeze them."
  @spec pause(Socket.t()) :: Socket.t()
  def pause(%{assigns: %{newest_seq: nil}} = socket), do: socket
  def pause(socket), do: freeze(socket)

  defp freeze(socket) do
    socket
    |> assign(:paused?, true)
    |> assign(:new_count, count_traces(socket.assigns.buffer))
    |> assign(:buffer, [])
  end

  @doc "Holds broadcast entries for the next flush; counts their traces while paused, drops them while searching."
  @spec absorb(Socket.t(), [map()]) :: Socket.t()
  def absorb(socket, []), do: socket

  def absorb(%{assigns: %{search: %{}}} = socket, _entries), do: socket

  def absorb(%{assigns: %{paused?: true}} = socket, entries),
    do: update(socket, :pending_count, &(&1 + count_traces(entries)))

  def absorb(socket, entries),
    do: update(socket, :buffer, &Enum.take(&1 ++ entries, -@flush_limit))

  @doc "Shows what `absorb/2` held: the traces counted while paused, or the newest rows."
  @spec flush(Socket.t()) :: Socket.t()
  def flush(%{assigns: %{paused?: true, pending_count: pending}} = socket) do
    socket
    |> update(:new_count, &(&1 + pending))
    |> assign(:pending_count, 0)
  end

  # Until the first page lands, the buffer cannot tell which entries that page already holds.
  def flush(%{assigns: %{search: nil, awaiting_ack?: false, newest_seq: newest_seq}} = socket)
      when is_integer(newest_seq) do
    case Enum.filter(socket.assigns.buffer, &(&1.seq > newest_seq)) do
      [] ->
        assign(socket, :buffer, [])

      rows ->
        socket
        |> put_live(rows, hd(rows).seq > newest_seq + 1)
        |> assign(:buffer, [])
        |> assign(:newest_seq, List.last(rows).seq)
        |> push_event("log-flushed", %{})
        |> assign(:awaiting_ack?, true)
    end
  end

  def flush(socket), do: socket

  @doc "The browser applied the last flush, so the next one may stream rows."
  @spec ack(Socket.t()) :: Socket.t()
  def ack(socket), do: assign(socket, :awaiting_ack?, false)

  @spec trace_rows([{integer(), atom()}]) :: non_neg_integer()
  def trace_rows(held), do: Enum.count(held, &match?({_seq, :trace}, &1))

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
    |> freeze()
    |> put_flash(:error, "Could not load the events.")
    |> halt()
  end

  defp handle_result(:older, {:exit, {:shutdown, :cancel}}, socket), do: halt(socket)

  defp handle_result(:older, _failed, socket) do
    socket
    |> put_flash(:error, "Could not load older events.")
    |> halt()
  end

  defp handle_result(_name, _result, socket), do: cont(socket)

  defp put_page(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, nil)

    # An older page still in flight was fetched below the stream this page replaces.
    socket
    |> cancel_async(:older)
    |> stream(:entries, rows, reset: true)
    |> assign(:newest_seq, newest_seq(entries))
    |> assign(:oldest_seq, oldest_seq(entries))
    |> assign(:held, held(rows))
  end

  defp put_older(socket, %{entries: entries, truncated?: truncated?}) do
    rows = with_evicted(entries, truncated?, socket.assigns.oldest_seq)

    socket
    |> stream(:entries, rows, at: -1)
    |> assign(:oldest_seq, oldest_seq(entries))
    |> update(:held, &(&1 ++ held(rows)))
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
          {[%{kind: :evicted, seq: entry.seq + 1}, entry], entry.seq}

        entry, _newer ->
          {[entry], entry.seq}
      end)

    rows
  end

  # absorb/2 dropped the entries before `rows`; Load older can only fetch them below the oldest row.
  defp put_live(socket, rows, true = _gap?) do
    socket
    |> cancel_async(:older)
    |> stream(:entries, live(rows), at: 0, reset: true)
    |> assign(:held, Enum.reverse(held(rows)))
    |> assign(:oldest_seq, hd(rows).seq)
  end

  defp put_live(socket, rows, false) do
    held = Enum.take(Enum.reverse(held(rows)) ++ socket.assigns.held, @row_limit)

    socket
    |> stream(:entries, live(rows), at: 0, limit: @row_limit)
    |> assign(:held, held)
    |> trim_oldest_seq(held)
  end

  defp live(rows), do: Enum.map(rows, &Map.put(&1, :live, true))

  defp trim_oldest_seq(socket, held) when length(held) == @row_limit,
    do: assign(socket, :oldest_seq, held |> List.last() |> elem(0))

  defp trim_oldest_seq(socket, _held), do: socket

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

  defp held(rows), do: Enum.map(rows, &{&1.seq, &1.kind})

  defp count_traces(entries), do: Enum.count(entries, &(&1.kind == :trace))

  defp entry_dom_id(%{kind: :evicted, seq: seq}), do: "entry-evicted-#{seq}"
  defp entry_dom_id(%{seq: seq}), do: "entry-#{seq}"
end
