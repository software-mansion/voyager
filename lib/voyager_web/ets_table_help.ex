defmodule VoyagerWeb.EtsTableHelp do
  @moduledoc """
  Static help/tooltip metadata for the ETS table details panel.

  Same entry shape as `VoyagerWeb.NodeInfoHelp`; entries are keyed by a stable
  atom and passed straight to the `help` attr of `kv/1`.
  """

  @type entry :: VoyagerWeb.NodeInfoHelp.entry()

  @ets "https://www.erlang.org/doc/apps/stdlib/ets.html"
  @new @ets <> "#new/2"
  @info @ets <> "#info/2"

  @entries %{
    type: %{
      text:
        "How objects are stored: set (unique keys, hash), ordered_set (unique keys, sorted), bag (many objects per key, no duplicates) or duplicate_bag (duplicates allowed).",
      doc_href: @new,
      doc_label: "See ets:new/2 table types"
    },
    protection: %{
      text:
        "Who may access the table: public (any process), protected (owner writes, anyone reads) or private (owner only). Voyager cannot peek into private tables.",
      doc_href: @new,
      doc_label: "See ets:new/2 access rights"
    },
    named_table: %{
      text:
        "Whether the table is registered under its name so it can be reached by atom instead of the table reference.",
      doc_href: @new,
      doc_label: "See ets:new/2 named_table"
    },
    keypos: %{
      text: "1-based position of the key inside each stored tuple. Defaults to 1.",
      doc_href: @new,
      doc_label: "See ets:new/2 keypos"
    },
    owner: %{
      text:
        "Process that owns the table. The table is deleted when its owner exits unless an heir takes it over.",
      doc_href: @info,
      doc_label: "See ets:info(owner)"
    },
    heir: %{
      text:
        "Process that inherits the table when the owner exits. none means the table dies with its owner.",
      doc_href: @new,
      doc_label: "See ets:new/2 heir"
    },
    size: %{
      text: "Number of objects stored in the table.",
      doc_href: @info,
      doc_label: "See ets:info(size)"
    },
    memory: %{
      text: "Memory used by the table, converted from machine words to bytes.",
      doc_href: @info,
      doc_label: "See ets:info(memory)"
    },
    compressed: %{
      text:
        "Whether objects are stored compressed. Saves memory at the cost of slower reads and matching.",
      doc_href: @new,
      doc_label: "See ets:new/2 compressed"
    },
    read_concurrency: %{
      text:
        "Optimises for many concurrent reads at the cost of slower switching between reads and writes.",
      doc_href: @ets <> "#concurrency",
      doc_label: "See ETS concurrency"
    },
    write_concurrency: %{
      text:
        "Lets different objects be written concurrently by using fine-grained locks instead of one table lock.",
      doc_href: @ets <> "#concurrency",
      doc_label: "See ETS concurrency"
    },
    decentralized_counters: %{
      text:
        "Keeps size and memory counters per scheduler instead of in one shared counter, so concurrent writes scale better while ets:info/2 becomes slower.",
      doc_href: @new,
      doc_label: "See ets:new/2 decentralized_counters"
    }
  }

  @spec get(atom()) :: entry() | nil
  def get(key), do: Map.get(@entries, key)
end
