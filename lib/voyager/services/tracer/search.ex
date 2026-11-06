defmodule Voyager.Services.Tracer.Search do
  @moduledoc """
  The text a trace is matched on, in both stores: `text/1` is what a saved trace's
  `search_text` column holds and what an unsaved one is filtered on. Pids are written
  `<0.X.Y>` whatever their node, as a node's index differs per Voyager run and connection,
  and `query/1` folds a query's pids the same way.
  Case folds ASCII only, so the in-memory filter and SQLite's `LIKE` agree.
  """

  alias Voyager.Services.Tracer.Entry

  @spec text(Entry.t()) :: String.t()
  def text(%{mfa: {m, f, a}} = entry) do
    terms = for key <- [:args, :value], Map.has_key?(entry, key), do: inspect_term(entry[key])

    Enum.join(
      [
        inspect_term(entry.pid),
        inspect_term(entry.process),
        Exception.format_mfa(m, f, a) | terms
      ],
      " "
    )
  end

  @spec query(String.t()) :: String.t()
  def query(query), do: zero_node(query)

  @doc """
  The trace entries containing `query`, ignoring ASCII case, with `seq` below `:before`,
  up to `:limit` of them; `total` counts every match whatever `:before` is.
  """
  @spec filter([Entry.t()], String.t(), before: non_neg_integer(), limit: pos_integer()) ::
          %{entries: [Entry.t()], total: non_neg_integer()}
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

    %{entries: page, total: length(matches)}
  end

  defp inspect_term(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity, inspect_fun: &inspect_pid/2)

  defp inspect_pid(pid, _opts) when is_pid(pid), do: zero_node(inspect(pid))
  defp inspect_pid(term, opts), do: Inspect.inspect(term, opts)

  defp zero_node(text), do: Regex.replace(~r/<\d+\.(?=\d+\.\d+>)/, text, "<0.")
end
