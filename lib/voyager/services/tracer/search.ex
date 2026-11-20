defmodule Voyager.Services.Tracer.Search do
  @moduledoc """
  The text a trace is matched on, in both stores: `text/1` is what a saved trace's
  `search_text` column holds, and `filter/4` matches an unsaved trace on its line of it. Pids
  are written `<0.X.Y>` whatever their node, as a node's index differs per Voyager run and
  connection, and `query/1` folds a query's pids the same way.
  Case folds ASCII only, so the in-memory filter and SQLite's `LIKE` agree.
  """

  alias Voyager.Services.TermSyntax
  alias Voyager.Services.Tracer.Entry
  alias Voyager.TermFormatter.Erlang, as: ErlangFormatter

  @doc """
  The Elixir line, a newline, then the Erlang line, each written as a row shows the trace, so a
  search matches only the syntax rows are shown in. Neither line holds a newline.
  """
  @spec text(Entry.t()) :: String.t()
  def text(entry), do: line(entry, :elixir) <> "\n" <> line(entry, :erlang)

  defp line(entry, :elixir),
    do: line(entry, &inspect_term/1, fn {m, f, a} -> Exception.format_mfa(m, f, a) end)

  defp line(entry, :erlang), do: line(entry, &erlang_term/1, &ErlangFormatter.format_mfa/1)

  defp line(%{mfa: mfa} = entry, format_term, format_mfa) do
    terms =
      for key <- [:args, :value],
          Map.has_key?(entry, key),
          do: term_text(key, entry[key], format_term)

    Enum.join(
      [format_term.(entry.pid), format_term.(entry.process), format_mfa.(mfa) | terms],
      " "
    )
  end

  # Rows write each argument on its own; the whole list `[65]` would print as `~c"A"`.
  defp term_text(:args, args, format_term) when is_list(args),
    do: "(" <> Enum.map_join(args, ", ", format_term) <> ")"

  defp term_text(_key, term, format_term), do: format_term.(term)

  @spec query(String.t()) :: String.t()
  def query(query), do: zero_node(query)

  @doc """
  The trace entries whose `syntax` line contains `query`, ignoring ASCII case, with `seq` below
  `:before`, up to `:limit` of them; `total` counts every match, and is nil once `:before` is given.
  """
  @spec filter([Entry.t()], String.t(), TermSyntax.syntax(),
          before: non_neg_integer(),
          limit: pos_integer()
        ) :: %{entries: [Entry.t()], total: non_neg_integer() | nil}
  def filter(entries, query, syntax, opts) do
    query = String.downcase(query, :ascii)

    matches =
      Enum.filter(entries, fn entry ->
        entry.kind == :trace and
          entry
          |> line(syntax)
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
