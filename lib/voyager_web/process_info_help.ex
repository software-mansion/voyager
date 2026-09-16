defmodule VoyagerWeb.ProcessInfoHelp do
  @moduledoc """
  Static help/tooltip metadata for the process overview and memory rows.

  Same entry shape as `VoyagerWeb.NodeInfoHelp`; entries are keyed by a stable
  atom and passed straight to the `help` attr of `kv/1`.
  """

  @type entry :: VoyagerWeb.NodeInfoHelp.entry()

  @erts "https://www.erlang.org/doc/apps/erts/erlang.html"
  @process_info @erts <> "#process_info/2"

  @entries %{
    pid: %{
      text:
        "Unique identifier of the process. The first number refers to the node the process runs on, the other two to the process itself.",
      doc_href: "https://www.erlang.org/doc/system/data_types.html#pid",
      doc_label: "Learn about pids"
    },
    initial_call: %{
      text:
        "The module, function and arity the process was spawned with. For OTP behaviours this is the generic entry point (e.g. proc_lib:init_p/5), not your callback module.",
      doc_href: @process_info,
      doc_label: "See process_info(initial_call)"
    },
    current_function: %{
      text:
        "The function the process is executing right now, or was executing when last scheduled out.",
      doc_href: @process_info,
      doc_label: "See process_info(current_function)"
    },
    current_stacktrace: %{
      text:
        "Which functions the process is inside right now, innermost first. A process sitting in gen_server.loop is idle and waiting for a message; anything else is what it is busy with or blocked on.",
      doc_href: @erts <> "#process_info_current_stacktrace",
      doc_label: "See process_info(current_stacktrace)"
    },
    registered_name: %{
      text: "Atom the process is registered under with erlang:register/2, if any.",
      doc_href: @process_info,
      doc_label: "See process_info(registered_name)"
    },
    label: %{
      text:
        "Free-form label set with proc_lib:set_label/1. A human-readable name for processes that are not registered.",
      doc_href: "https://www.erlang.org/doc/apps/stdlib/proc_lib.html#set_label/1",
      doc_label: "See proc_lib:set_label/1"
    },
    parent: %{
      text:
        "The process that spawned this one. Not the same as the supervisor: a supervisor is the parent only when it spawned the child directly.",
      doc_href: @process_info,
      doc_label: "See process_info(parent)"
    },
    status: %{
      text:
        "Scheduling state: running, runnable (waiting for a scheduler), waiting (in receive), suspended, exiting or garbage_collecting.",
      doc_href: @process_info,
      doc_label: "See process_info(status)"
    },
    message_queue_len: %{
      text:
        "Number of messages in the mailbox. A queue that keeps growing means the process cannot keep up with its senders.",
      doc_href: @process_info,
      doc_label: "See process_info(message_queue_len)"
    },
    message_queue_data: %{
      text:
        "Where mailbox messages are stored: on_heap (default, faster) or off_heap (outside the heap, better for very large mailboxes).",
      doc_href: @erts <> "#process_flag_message_queue_data",
      doc_label: "See process_flag(message_queue_data)"
    },
    group_leader: %{
      text:
        "Process that receives this process's I/O, such as io:format output. Usually the application master or the shell.",
      doc_href: @process_info,
      doc_label: "See process_info(group_leader)"
    },
    priority: %{
      text:
        "Scheduling priority: low, normal, high or max. Anything other than normal should be a deliberate choice.",
      doc_href: @erts <> "#process_flag_priority",
      doc_label: "See process_flag(priority)"
    },
    trap_exit: %{
      text:
        "When true, exit signals from linked processes arrive as {'EXIT', Pid, Reason} messages instead of killing this process.",
      doc_href: @erts <> "#process_flag_trap_exit",
      doc_label: "See process_flag(trap_exit)"
    },
    reductions: %{
      text:
        "Work done by this process since it started, in reductions (roughly function calls). Compare between refreshes to see how busy it is.",
      doc_href: @process_info,
      doc_label: "See process_info(reductions)"
    },
    last_calls: %{
      text:
        "Recent calls recorded when call saving is enabled with process_flag(save_calls, N). Empty on most processes.",
      doc_href: @process_info,
      doc_label: "See process_info(last_calls)"
    },
    catch_level: %{
      text: "Number of active catch expressions the process is currently inside.",
      doc_href: @process_info,
      doc_label: "See process_info(catch_level)"
    },
    trace: %{
      text:
        "Internal trace flags bitmask. Non-zero only when tracing is enabled for this process.",
      doc_href: @process_info,
      doc_label: "See process_info(trace)"
    },
    suspending: %{
      text:
        "Processes this one has suspended with erlang:suspend_process/1, with their suspend counts.",
      doc_href: @process_info,
      doc_label: "See process_info(suspending)"
    },
    sequential_trace_token: %{
      text:
        "Token used by the seq_trace facility to follow a message flow across processes. Empty unless seq_trace is active.",
      doc_href: "https://www.erlang.org/doc/apps/kernel/seq_trace.html",
      doc_label: "See seq_trace"
    },
    error_handler: %{
      text:
        "Module called when the process calls an undefined function. Almost always error_handler.",
      doc_href: @erts <> "#process_flag_error_handler",
      doc_label: "See process_flag(error_handler)"
    },
    memory: %{
      text:
        "Total memory of the process in bytes: stack, heaps, message queue and process control block. Binaries larger than 64 bytes live outside the process and are not counted.",
      doc_href: @erts <> "#process_info_memory",
      doc_label: "See process_info(memory)"
    },
    stack_and_heap_size: %{
      text: "Combined size of the stack and all heap generations, in bytes.",
      doc_href: @erts <> "#process_info_total_heap_size",
      doc_label: "See process_info(total_heap_size)"
    },
    heap_size: %{
      text:
        "Size of the youngest heap generation, in bytes. Grows as the process allocates and shrinks after garbage collection.",
      doc_href: @process_info,
      doc_label: "See process_info(heap_size)"
    },
    stack_size: %{
      text: "Size of the process stack, in bytes. A deep stack usually means deep recursion.",
      doc_href: @process_info,
      doc_label: "See process_info(stack_size)"
    },
    gc_min_heap_size: %{
      text: "Minimum heap size the garbage collector will shrink the process down to.",
      doc_href: @erts <> "#process_flag_min_heap_size",
      doc_label: "See process_flag(min_heap_size)"
    },
    gc_fullsweep_after: %{
      text:
        "Number of generational collections before a full-sweep collection is forced. Lower values reclaim old data sooner at a CPU cost.",
      doc_href: @erts <> "#process_info_garbage_collection_info",
      doc_label: "See process_info(garbage_collection)"
    }
  }

  @spec get(atom()) :: entry() | nil
  def get(key), do: Map.get(@entries, key)
end
