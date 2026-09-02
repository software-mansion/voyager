-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([proc_top/5]).
-export([proc_links/2, proc_monitors/2, proc_monitored_by/2]).
-export([proc_dictionary/3, proc_messages/3, proc_label/2, proc_state/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export_type([bounded/1, monitor/0, dict_entry/0, truncated_term/0]).

-record(state, {nodes = #{} :: #{node() => true}}).

%% Substituted wherever a subterm was dropped, so the surrounding shape of a
%% truncated term stays intact and the reader can tell data from elision.
-define(TRUNCATED, '$voyager_truncated').
%% A single binary carries no nesting for the term budget to walk into, so it
%% is additionally capped here regardless of how much budget remains.
-define(MAX_BINARY_BYTES, 4096).

-type state() :: #state{nodes :: #{node() => true}}.

%% =====================================================================
%% REGISTER - Adds the Voyager node to the watched set and returns the server pid.
%% =====================================================================

%% Bounds the start/register retry so a node whose agent keeps stopping
%% cannot spin here forever.
-define(MAX_REGISTER_ATTEMPTS, 3).

%% Adds the Voyager node to the watched set and returns the server pid.
%% If the server is not running, it starts it and registers the Voyager node.
%% Uses `gen_server:start/4` so the process outlives the transient erpc caller.
%% A failed `init/1` purges the module
-spec register(node()) -> {ok, pid()} | {error, term()}.
register(VoyagerNode) when is_atom(VoyagerNode) ->
    do_start(VoyagerNode, ?MAX_REGISTER_ATTEMPTS).

-spec do_start(node(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
do_start(_VoyagerNode, 0) ->
    {error, unavailable};
do_start(VoyagerNode, Attempts) ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, VoyagerNode, []) of
                {ok, Pid} ->
                    {ok, Pid};
                {error, {already_started, _Pid}} ->
                    do_register(VoyagerNode, Attempts);
                _Error ->
                    %% terminate/2 is not called when init/1 fails, so unload here or the
                    %% module stays loaded on the node after a failed register/1.
                    %% it purges the code so this return value is ignored.
                    purge_code()
            end;
        _Pid ->
            do_register(VoyagerNode, Attempts)
    end.

%% The agent stops itself when its last Voyager node goes down, so it can be gone between `whereis/1` above and this call.
%% Depending on timing the call then exits with `noproc` (already gone), or with the server's being `killed`.
%% Retry the whole start/register sequence when that occurs.
-spec do_register(node(), pos_integer()) -> {ok, pid()} | {error, term()}.
do_register(VoyagerNode, Attempts) ->
    try gen_server:call(?MODULE, {register, VoyagerNode}) of
        {ok, Pid} ->
            {ok, Pid};
        {error, _} = Error ->
            Error
    catch
        exit:{noproc, _} ->
            do_start(VoyagerNode, Attempts - 1);
        exit:{killed, _} ->
            do_start(VoyagerNode, Attempts - 1)
    end.

%% =====================================================================
%% PROCESS LIST - Remote process table scanning.
%% =====================================================================

%% Returns `{Entries, TotalCount}': the top `Limit' processes by `SortBy'
%% (`desc' largest first, `asc' smallest), and the number of processes actually
%% walked during the scan (before `Limit'/`Search').
%%
%% Runs on the remote node, walking the process table with an iterator and
%% keeping only the top-`Limit' in memory, guarded by a `max_heap_size' flag
%% that kills the transient worker (not the node) on a pathological scan.
%%
%% Each entry is a map of the requested `Attrs' plus `pid'; `SortBy' must be one
%% of `Attrs' and resolve to an integer. A non-`undefined'/non-empty `Search'
%% keeps only processes whose `pid' or a non-numeric attribute contains it,
%% case-insensitively.
-spec proc_top([atom()], atom(), integer(), asc | desc, undefined | iodata()) ->
                  {[map()], non_neg_integer()}.
proc_top(Attrs, SortBy, Limit, Direction, Search) ->
    with_bounded_heap(fun() -> scan(Attrs, SortBy, Limit, Direction, needle(Search)) end).

scan(Attrs, SortBy, Limit, Direction, Needle) ->
    {Top, Scanned} =
        fold(iterator(), Attrs, SortBy, Limit, Direction, Needle, gb_trees:empty(), 0, 0),
    {finalize(Top, Direction), Scanned}.

%% `gb_trees:to_list/1' yields entries ascending by `{Value, Pid}', which is
%% already best-to-worst for `asc' and needs reversing for `desc'.
finalize(Top, Direction) ->
    Entries = [to_map(Entry) || Entry <- gb_trees:to_list(Top)],
    case Direction of
        asc ->
            Entries;
        desc ->
            lists:reverse(Entries)
    end.

%% Prefer the incremental iterator (OTP 27+); fall back to a plain list.
iterator() ->
    case erlang:function_exported(erlang, processes_iterator, 0) of
        true ->
            {iter, erlang:processes_iterator()};
        false ->
            {list, erlang:processes()}
    end.

next({iter, Iter}) ->
    case erlang:processes_next(Iter) of
        {Pid, NextIter} ->
            {Pid, {iter, NextIter}};
        none ->
            none
    end;
next({list, []}) ->
    none;
next({list, [Pid | Rest]}) ->
    {Pid, {list, Rest}}.

fold(State, Attrs, SortBy, Limit, Direction, Needle, Top, Size, Scanned) ->
    case next(State) of
        {Pid, NextState} ->
            {NewTop, NewSize} =
                maybe_insert(Pid, Attrs, SortBy, Limit, Direction, Needle, Top, Size),
            fold(NextState, Attrs, SortBy, Limit, Direction, Needle, NewTop, NewSize, Scanned + 1);
        none ->
            {Top, Scanned}
    end.

maybe_insert(Pid, Attrs, SortBy, Limit, Direction, Needle, Top, Size) ->
    case erlang:process_info(Pid, Attrs) of
        Info when is_list(Info) ->
            case value(SortBy, Info) of
                Value when is_integer(Value) ->
                    case matches(Needle, Pid, Info) of
                        true ->
                            insert(Top, Size, Limit, Direction, Value, Pid, Info);
                        false ->
                            {Top, Size}
                    end;
                _ ->
                    {Top, Size}
            end;
        _ ->
            {Top, Size}
    end.

insert(Top, Size, Limit, _Direction, _Value, _Pid, _Info) when Limit =< 0 ->
    {Top, Size};
insert(Top, Size, Limit, _Direction, Value, Pid, Info) when Size < Limit ->
    {gb_trees:insert({Value, Pid}, Info, Top), Size + 1};
insert(Top, Size, _Limit, Direction, Value, Pid, Info) ->
    {{WorstValue, _}, _, Rest} = take_worst(Direction, Top),
    case better(Direction, Value, WorstValue) of
        true ->
            {gb_trees:insert({Value, Pid}, Info, Rest), Size};
        false ->
            {Top, Size}
    end.

take_worst(desc, Top) ->
    gb_trees:take_smallest(Top);
take_worst(asc, Top) ->
    gb_trees:take_largest(Top).

better(desc, Value, Threshold) ->
    Value > Threshold;
better(asc, Value, Threshold) ->
    Value < Threshold.

value(SortBy, Info) ->
    case lists:keyfind(SortBy, 1, Info) of
        {SortBy, Value} ->
            Value;
        false ->
            undefined
    end.

%% Lowercase the search term once; `undefined'/empty means "no filter".
needle(undefined) ->
    undefined;
needle(Search) ->
    case string:lowercase(
             unicode:characters_to_binary(Search))
    of
        <<>> ->
            undefined;
        Needle ->
            Needle
    end.

%% A process matches when its `pid' or any requested non-numeric attribute
%% contains the (already lowercased) needle. Integer attributes are skipped.
matches(undefined, _Pid, _Info) ->
    true;
matches(Needle, Pid, Info) ->
    contains(Needle, list_to_binary(erlang:pid_to_list(Pid)))
    orelse lists:any(fun({_Key, Value}) -> contains(Needle, Value) end, Info).

contains(_Needle, Value) when is_integer(Value) ->
    false;
contains(Needle, Value) ->
    Haystack = string:lowercase(to_search_string(Value)),
    string:find(Haystack, Needle) =/= nomatch.

to_search_string(Value) when is_binary(Value) ->
    Value;
to_search_string(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
to_search_string(Value) ->
    unicode:characters_to_binary(
        io_lib:format("~p", [Value])).

to_map({{_Value, Pid}, Info}) ->
    maps:from_list([{pid, Pid} | Info]).

%% =====================================================================
%% PROCESS INFO - Remote process info fetching.
%% =====================================================================

%% A truncated view of an unbounded attribute. `total' is the real length on the
%% remote, `items' holds at most `Limit' entries, and `truncated' says whether
%% anything was dropped - so callers can surface the gap instead of silently
%% showing a partial list as if it were complete.
-type bounded(Item) ::
    #{total := non_neg_integer(),
      truncated := boolean(),
      items := [Item]}.
-type monitor() :: {process, pid() | {atom(), node()}} | {port, port()}.
-type dict_entry() :: {term(), term()}.
%% A single term rewritten to fit a budget. `truncated' says whether anything
%% was dropped - a budget elision or a capped binary.
-type truncated_term() :: #{term := term(), truncated := boolean()}.

%% Links and monitors are returned as raw terms - they are needed as identifiers
%% (navigating to a process), and only their length is unbounded, which `Limit'
%% caps on the remote.
-spec proc_links(pid(), non_neg_integer()) ->
                    {ok, bounded(pid() | port())} | {error, dead}.
proc_links(Pid, Limit) ->
    bounded_attribute(Pid, links, Limit, unbounded).

-spec proc_monitors(pid(), non_neg_integer()) -> {ok, bounded(monitor())} | {error, dead}.
proc_monitors(Pid, Limit) ->
    bounded_attribute(Pid, monitors, Limit, unbounded).

-spec proc_monitored_by(pid(), non_neg_integer()) ->
                           {ok, bounded(pid() | port())} | {error, dead}.
proc_monitored_by(Pid, Limit) ->
    bounded_attribute(Pid, monitored_by, Limit, unbounded).

%% Dictionary entries are arbitrary user terms, so `Limit' caps how many are
%% kept and `Budget' caps how much of them is walked (see `bound_term/2').
-spec proc_dictionary(pid(), non_neg_integer(), non_neg_integer()) ->
                         {ok, bounded(dict_entry())} | {error, dead}.
proc_dictionary(Pid, Limit, Budget) ->
    bounded_attribute(Pid, dictionary, Limit, Budget).

%% `erlang:process_info(Pid, messages)' copies the *whole* mailbox onto this
%% process' heap - there is no capped mailbox read in ERTS - so truncating here
%% bounds only what crosses the wire. The `max_heap_size' cap is what keeps a
%% multi-million-message mailbox from taking the node down with it.
-spec proc_messages(pid(), non_neg_integer(), non_neg_integer()) ->
                       {ok, bounded(term())} | {error, dead}.
proc_messages(Pid, Limit, Budget) ->
    bounded_attribute(Pid, messages, Limit, Budget).

%% A label is set with `proc_lib:set_label/1' and can be any term, hence the
%% budget. `undefined' means no label was set.
-spec proc_label(pid(), non_neg_integer()) -> {ok, truncated_term()} | {error, dead}.
proc_label(Pid, Budget) when is_pid(Pid), is_integer(Budget), Budget >= 0 ->
    with_bounded_heap(fun() ->
                         case erlang:process_info(Pid, label) of
                             undefined -> {error, dead};
                             {label, Label} -> {ok, truncated_term(Label, Budget)}
                         end
                      end).

%% `sys:get_state/2' only answers for processes that handle system messages, and
%% a raw process is indistinguishable from a busy one here: neither replies, so
%% both surface as `timeout'. `Timeout' must stay below the caller's own so this
%% returns an error instead of the call being cut off.
-spec proc_state(pid(), non_neg_integer(), timeout()) ->
                    {ok, truncated_term()} | {error, dead | timeout | no_state}.
proc_state(Pid, Budget, Timeout) when is_pid(Pid), is_integer(Budget), Budget >= 0 ->
    with_bounded_heap(fun() -> do_proc_state(Pid, Budget, Timeout) end).

do_proc_state(Pid, Budget, Timeout) ->
    try sys:get_state(Pid, Timeout) of
        State ->
            {ok, truncated_term(State, Budget)}
    catch
        exit:{noproc, _} ->
            {error, dead};
        exit:{timeout, _} ->
            state_timeout(Pid);
        _Kind:_Reason ->
            {error, no_state}
    end.

state_timeout(Pid) ->
    case is_process_alive(Pid) of
        true ->
            {error, timeout};
        false ->
            {error, dead}
    end.

%% `unbounded' skips the term walk for attributes whose elements are fixed-size
%% identifiers (pids, ports) - there the count cap is the whole story.
-spec bounded_attribute(pid(),
                        links | monitors | monitored_by | dictionary | messages,
                        non_neg_integer(),
                        non_neg_integer() | unbounded) ->
                           {ok, bounded(term())} | {error, dead}.
bounded_attribute(Pid, Key, Limit, Budget)
    when is_pid(Pid), is_integer(Limit), Limit >= 0 ->
    with_bounded_heap(fun() -> do_bounded_attribute(Pid, Key, Limit, Budget) end).

-spec do_bounded_attribute(pid(),
                           links | monitors | monitored_by | dictionary | messages,
                           non_neg_integer(),
                           non_neg_integer() | unbounded) ->
                              {ok, bounded(term())} | {error, dead}.
do_bounded_attribute(Pid, Key, Limit, Budget) ->
    case erlang:process_info(Pid, Key) of
        undefined ->
            {error, dead};
        {Key, Items} when is_list(Items) ->
            Total = length(Items),
            {Kept, Truncated} = bound_items(lists:sublist(Items, Limit), Budget),
            {ok,
             #{total => Total,
               truncated => Total > Limit orelse Truncated,
               items => Kept}}
    end.

bound_items(Items, unbounded) ->
    {Items, false};
bound_items(Items, Budget) when is_integer(Budget), Budget >= 0 ->
    bound_entries(Items, Budget, false, []).

%% Each entry is budgeted on its own, so a budget that runs out mid-list drops
%% the tail instead of appending a bare `?TRUNCATED' as an element and breaking
%% the entry shape (e.g. `dict_entry()') callers expect from `items'.
bound_entries([], _Budget, Truncated, Acc) ->
    {lists:reverse(Acc), Truncated};
bound_entries([_ | _], 0, _Truncated, Acc) ->
    {lists:reverse(Acc), true};
bound_entries([Item | Rest], Budget, Truncated, Acc) ->
    {Bounded, NewBudget, NewTruncated} = walk(Item, Budget, Truncated),
    bound_entries(Rest, NewBudget, NewTruncated, [Bounded | Acc]).

truncated_term(Term, Budget) ->
    {Bounded, Truncated} = bound_term(Term, Budget),
    #{term => Bounded, truncated => Truncated}.

%% Rewrites `Term' into a bounded copy of itself, keeping it a raw term so the
%% GUI can still render it as a tree. Substituting `?TRUNCATED' the moment
%% `Budget' runs out, instead of descending further, bounds the cost by
%% `Budget' and *not* by the size of `Term' - which is what makes it safe to
%% point at a multi-gigabyte process state. Containers are therefore never
%% materialised: maps are walked with an iterator, lists cons cell at a time,
%% tuples by index.
-spec bound_term(term(), non_neg_integer()) -> {term(), boolean()}.
bound_term(Term, Budget) ->
    {Bounded, _Rest, Truncated} = walk(Term, Budget, false),
    {Bounded, Truncated}.

walk(_Term, 0, _Truncated) ->
    {?TRUNCATED, 0, true};
walk(Term, Budget, Truncated) when is_list(Term) ->
    walk_list(Term, Budget - 1, Truncated, []);
walk(Term, Budget, Truncated) when is_map(Term) ->
    walk_map(maps:iterator(Term), Budget - 1, Truncated, #{});
walk(Term, Budget, Truncated) when is_tuple(Term) ->
    walk_tuple(Term, 1, tuple_size(Term), Budget - 1, Truncated, []);
walk(Term, Budget, Truncated) when is_bitstring(Term) ->
    walk_bitstring(Term, Budget, Truncated);
walk(Term, Budget, Truncated) ->
    {Term, Budget - 1, Truncated}.

walk_list([], Budget, Truncated, Acc) ->
    {lists:reverse(Acc), Budget, Truncated};
walk_list(_Tail, 0, _Truncated, Acc) ->
    {lists:reverse([?TRUNCATED | Acc]), 0, true};
walk_list([Head | Tail], Budget, Truncated, Acc) ->
    {NewHead, NewBudget, NewTruncated} = walk(Head, Budget, Truncated),
    walk_list(Tail, NewBudget, NewTruncated, [NewHead | Acc]);
%% Improper tail: keep the list improper rather than silently repairing it.
walk_list(Tail, Budget, Truncated, Acc) ->
    {NewTail, NewBudget, NewTruncated} = walk(Tail, Budget, Truncated),
    {lists:reverse(Acc, NewTail), NewBudget, NewTruncated}.

%% Two keys can both truncate to `?TRUNCATED' and collide, shrinking the map.
%% `truncated' is already true in that case, so the gap is reported either way.
walk_map(Iterator, Budget, Truncated, Acc) ->
    case maps:next(Iterator) of
        none ->
            {Acc, Budget, Truncated};
        {_Key, _Value, _Next} when Budget =:= 0 ->
            {Acc#{?TRUNCATED => ?TRUNCATED}, 0, true};
        {Key, Value, Next} ->
            {NewKey, KeyBudget, KeyTruncated} = walk(Key, Budget, Truncated),
            {NewValue, NewBudget, NewTruncated} = walk(Value, KeyBudget, KeyTruncated),
            walk_map(Next, NewBudget, NewTruncated, Acc#{NewKey => NewValue})
    end.

walk_tuple(_Tuple, Index, Size, Budget, Truncated, Acc) when Index > Size ->
    {list_to_tuple(lists:reverse(Acc)), Budget, Truncated};
walk_tuple(_Tuple, _Index, _Size, 0, _Truncated, Acc) ->
    {list_to_tuple(lists:reverse([?TRUNCATED | Acc])), 0, true};
walk_tuple(Tuple, Index, Size, Budget, Truncated, Acc) ->
    {New, NewBudget, NewTruncated} = walk(element(Index, Tuple), Budget, Truncated),
    walk_tuple(Tuple, Index + 1, Size, NewBudget, NewTruncated, [New | Acc]).

%% Charged per byte kept rather than a flat unit: a flat charge lets any number
%% of binaries each pay the same regardless of size, so they could still ship
%% megabytes under a small budget. Floored at 1 so an empty binary cannot walk
%% for free. Only the visible part of a sub-binary is copied over distribution,
%% so cutting here really does bound the payload.
walk_bitstring(Bin, Budget, Truncated) when is_binary(Bin) ->
    Cost = max(min(min(?MAX_BINARY_BYTES, byte_size(Bin)), Budget), 1),
    {binary:part(Bin, 0, min(Cost, byte_size(Bin))),
     Budget - Cost,
     Truncated orelse Cost < byte_size(Bin)};
%% A non-byte-aligned bitstring cannot be cut with `binary:part/3', so an
%% oversized one is dropped whole.
walk_bitstring(Bits, Budget, _Truncated) when bit_size(Bits) > ?MAX_BINARY_BYTES * 8 ->
    {?TRUNCATED, Budget - 1, true};
walk_bitstring(Bits, Budget, Truncated) ->
    {Bits, Budget - 1, Truncated}.

%% Runs `Fun' with this process' heap capped (10_000_000 words ~= 76MB on 64-bit, 8 bytes word size) so
%% a pathological scan is killed rather than the node, restoring the previous
%% `max_heap_size' afterwards. The scanning functions are also called in-process
%% (not only from a throwaway erpc worker), so the flag must not leak out.
-spec with_bounded_heap(fun(() -> Result)) -> Result.
with_bounded_heap(Fun) ->
    Old = process_flag(max_heap_size,
                       #{size => 10_000_000,
                         kill => true,
                         error_logger => true}),
    try
        Fun()
    after
        process_flag(max_heap_size, Old)
    end.

%% =====================================================================
%% NODE WATCHER - gen_server callbacks and watcher for Nodes.
%% =====================================================================

-spec init(node()) -> {ok, state()} | {stop, term()}.
init(VoyagerNode) when is_atom(VoyagerNode) ->
    %% Turns an incoming exit signal into an {'EXIT', _, _} message that handle_info/2 stops on.
    process_flag(trap_exit, true),
    case add_node(#state{nodes = #{}}, VoyagerNode) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call({register, node()} | term(), {pid(), term()}, state()) ->
                     {reply, {ok, pid()} | {error, term()}, state()}.
handle_call({register, VoyagerNode}, _From, State) when is_atom(VoyagerNode) ->
    case add_node(State, VoyagerNode) of
        {ok, NewState} ->
            {reply, {ok, self()}, NewState};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) ->
                     {noreply, state()} | {stop, normal | shutdown, state()}.
handle_info({nodedown, VoyagerNode}, State) ->
    case remove_node(State, VoyagerNode) of
        {0, NewState} ->
            {stop, normal, NewState};
        {_, NewState} ->
            {noreply, NewState}
    end;
handle_info({'EXIT', _From, _Reason}, State) ->
    {stop, shutdown, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    purge_code().

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% Subscribe to nodedown for VoyagerNode.
%% Duplicate registers are a no-op so `erlang:monitor_node/2` does not stack subscriptions.
%% If Node cannot be reached, `erlang:monitor_node(Node, true)` delivers `{nodedown, Node}` to this process.
%% `erlang:monitor_node/2` raises `notalive` only when this VM is not distributed and Node is not 'nonode@nohost'.
-spec add_node(state(), node()) -> {ok, state()} | {error, nodedown}.
add_node(#state{nodes = Nodes} = State, VoyagerNode)
    when is_atom(VoyagerNode), is_map(Nodes) ->
    case maps:is_key(VoyagerNode, Nodes) of
        true ->
            {ok, State};
        false ->
            try erlang:monitor_node(VoyagerNode, true) of
                _ ->
                    {ok, State#state{nodes = Nodes#{VoyagerNode => true}}}
            catch
                error:notalive ->
                    {error, nodedown}
            end
    end.

-spec remove_node(state(), node()) -> {integer(), state()}.
remove_node(#state{nodes = Nodes} = State, VoyagerNode) ->
    NewState = State#state{nodes = maps:remove(VoyagerNode, Nodes)},
    {map_size(NewState#state.nodes), NewState}.

%% `purge` stops all processes running this module and deletes the module old module code.
%% `delete` moves current module code to old code.
%% second `purge` purges the old module code.
-spec purge_code() -> ok.
purge_code() ->
    code:purge(?MODULE),
    code:delete(?MODULE),
    code:purge(?MODULE),
    ok.
