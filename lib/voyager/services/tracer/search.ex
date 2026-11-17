defmodule Voyager.Services.Tracer.Search do
  @moduledoc """
  The text a trace is matched on, in both stores: `text/1` is what a saved trace's
  `search_text` column holds and what an unsaved one is filtered on. Pids are written
  `<0.X.Y>` whatever their node, as a node's index differs per Voyager run and connection,
  and `query/1` folds a query's pids the same way.
  Case folds ASCII only, so the in-memory filter and SQLite's `LIKE` agree.
  """

  alias Voyager.Services.Tracer.Entry
  alias Voyager.TermFormatter.Erlang, as: ErlangFormatter

  @doc "One line in Elixir syntax and one in Erlang, as rows follow the term syntax setting."
  @spec text(Entry.t()) :: String.t()
  def text(entry) do
    line(entry, &inspect_term/1, fn {m, f, a} -> Exception.format_mfa(m, f, a) end) <>
      "\n" <> line(entry, &erlang_term/1, &ErlangFormatter.format_mfa/1)
  end

  defp line(%{mfa: mfa} = entry, format_term, format_mfa) do
    terms = for key <- [:args, :value], Map.has_key?(entry, key), do: format_term.(entry[key])

    Enum.join(
      [format_term.(entry.pid), format_term.(entry.process), format_mfa.(mfa) | terms],
      " "
    )
  end

  @spec query(String.t()) :: String.t()
  def query(query), do: zero_node(query)

  @doc """
  The trace entries containing `query`, ignoring ASCII case, with `seq` below `:before`,
  up to `:limit` of them; `total` counts every match, and is nil once `:before` is given.
  """
  @spec filter([Entry.t()], String.t(), before: non_neg_integer(), limit: pos_integer()) ::
          %{entries: [Entry.t()], total: non_neg_integer() | nil}
  def filter(entries, query, opts) do
    query = String.downcase(query, :ascii)

    matches =
      Enum.filter(entries, fn entry ->
        entry.kind == :trace and
          entry
          |> text()
          |> String.downcase(:ascii)
          |> String.contains?(query)
      end)

    page =
      matches
      |> Enum.drop_while(&(opts[:before] && &1.seq >= opts[:before]))
      |> Enum.take(opts[:limit])

    %{entries: page, total: if(opts[:before], do: nil, else: length(matches))}
  end

  defp inspect_term(term),
    do:
      inspect(term,
        limit: :infinity,
        printable_limit: :infinity,
        inspect_fun: &inspect_pid/2
      )

  defp inspect_pid(pid, _opts) when is_pid(pid), do: zero_node(inspect(pid))
  defp inspect_pid(term, opts), do: Inspect.inspect(term, opts)

  defp erlang_term(term),
    do:
      term |> ErlangFormatter.inspect(limit: :infinity, printable_limit: :infinity) |> zero_node()

  defp zero_node(text), do: Regex.replace(~r/<\d+\.(?=\d+\.\d+>)/, text, "<0.")
end
