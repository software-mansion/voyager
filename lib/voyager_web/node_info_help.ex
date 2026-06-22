defmodule VoyagerWeb.NodeInfoHelp do
  @moduledoc """
  Static help/tooltip metadata for the node info dashboard.

  Single source of truth for the descriptions and documentation links shown in
  the `<.help_tooltip>` affordances across the page. Entries are keyed by a
  stable atom (not the display label) and share one shape so callers can pass an
  entry straight to `<.help_tooltip>`.

  Presentation metadata only — never mixed into `Voyager.Services.NodeInfo`
  snapshot data, which is dynamic and flows over RPC from the remote node.
  """

  @typedoc "A single help entry. `doc_href`/`doc_label` are optional."
  @type entry :: %{
          required(:text) => String.t(),
          optional(:doc_href) => String.t(),
          optional(:doc_label) => String.t()
        }

  @erts "https://www.erlang.org/doc/apps/erts/erlang.html"

  @entries %{
    # Stat tiles
    uptime: %{
      text: "Total wall-clock time since the node started, in milliseconds.",
      doc_href: @erts <> "#statistics_wall_clock",
      doc_label: "See erlang:statistics(wall_clock)"
    },
    io_input: %{
      text: "Total bytes received by the node through all ports since it started.",
      doc_href: @erts <> "#statistics/1",
      doc_label: "See erlang:statistics(io)"
    },
    io_output: %{
      text: "Total bytes sent by the node through all ports since it started.",
      doc_href: @erts <> "#statistics/1",
      doc_label: "See erlang:statistics(io)"
    },
    reductions: %{
      text:
        "Total reductions executed on this node since it started. A reduction is the BEAM's unit of work (roughly one function call).",
      doc_href: @erts <> "#statistics_reductions",
      doc_label: "See erlang:statistics(reductions)"
    },

    # Metric cards
    schedulers: %{
      text:
        "OS threads that execute Erlang processes. Normal schedulers run regular processes; dirty CPU schedulers handle long-running NIFs that would starve normal ones; dirty IO schedulers handle blocking I/O in NIFs. Online is how many are active; total is the configured maximum.",
      doc_href: @erts <> "#system_info_schedulers",
      doc_label: "See erlang:system_info(schedulers)"
    },
    run_queues: %{
      text:
        "Number of processes waiting to be picked up by a scheduler. A consistently non-zero queue means the node is CPU-bound. Normal + CPU combines the normal scheduler queues and dirty CPU queues; Dirty IO is the dirty I/O scheduler queue.",
      doc_href: @erts <> "#statistics_run_queue_lengths",
      doc_label: "See erlang:statistics(run_queue_lengths)"
    },

    # Memory card
    memory_breakdown: %{
      text:
        "Memory allocated by the BEAM VM, split by category: processes, binaries, loaded code, ETS tables, and the atom table. Other is derived as total minus those five categories.",
      doc_href: @erts <> "#memory/0",
      doc_label: "See erlang:memory()"
    },

    # Runtime rows
    otp: %{
      text:
        "OTP major release number. Determines which OTP applications and behaviours are available."
    },
    erts: %{
      text: "Erlang Runtime System version string. Versioned independently from OTP."
    },
    stdlib: %{
      text:
        "Version of the Erlang standard library (stdlib) OTP application running on this node."
    },
    elixir: %{
      text: "Elixir version running on this node, read from the :elixir OTP application."
    },
    gleam_stdlib: %{
      text:
        "Gleam standard library version running on this node, read from the :gleam_stdlib OTP application."
    },
    word_size: %{
      text: "Size of an Erlang term word on the heap, in bytes.",
      doc_href: @erts <> "#system_info_wordsize",
      doc_label: "See erlang:system_info(wordsize)"
    },
    async_threads: %{
      text:
        "Size of the async thread pool used for blocking operations in drivers. Separate from dirty I/O schedulers.",
      doc_href: @erts <> "#system_info_thread_pool_size",
      doc_label: "See erlang:system_info(thread_pool_size)"
    },
    system_arch: %{
      text: "Target system architecture string.",
      doc_href: @erts <> "#system_info_system_architecture",
      doc_label: "See erlang:system_info(system_architecture)"
    },

    # System limits rows
    processes: %{
      text: "Maximum number of concurrently existing processes.",
      doc_href: @erts <> "#system_info/1-system-limits",
      doc_label: "See erlang:system_info(process_limit)"
    },
    atoms: %{
      text: "Maximum number of atoms the VM can hold. Atoms are never garbage-collected.",
      doc_href: @erts <> "#system_info/1-system-limits",
      doc_label: "See erlang:system_info(atom_limit)"
    },
    ports: %{
      text: "Maximum number of concurrently open ports (file descriptors, sockets, drivers).",
      doc_href: @erts <> "#system_info/1-system-limits",
      doc_label: "See erlang:system_info(port_limit)"
    }
  }

  @doc """
  Returns the help entry for `key`, or `nil` when none is registered.
  """
  @spec get(atom()) :: entry() | nil
  def get(key), do: Map.get(@entries, key)
end
