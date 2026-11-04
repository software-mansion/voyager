-module(?AGENT).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([proc_top/5]).
-export([proc_links/2, proc_monitors/2, proc_monitored_by/2]).
-export([proc_dictionary/3, proc_messages/3, proc_label/2, proc_state/3]).
-export([ets_select_chunk/4, ets_lookup/5, ets_select_spec/5]).
-export([trace_start/3, trace_stop/1, trace_sessions/0]).
-export([trace_modules/0, trace_functions/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export_type([bounded/1, monitor/0, dict_entry/0, truncated_term/0]).

-record(state, {nodes = #{} :: #{node() => true}}).

%% Substituted wherever a subterm was dropped, so the surrounding shape of a
%% truncated term stays intact and the reader can tell data from elision.
-define(TRUNCATED, '$voyager_truncated').

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
walk(Term, Budget, Truncated) when is_function(Term) ->
    walk_uncuttable(Term, Budget, Truncated);
walk(Term, Budget, Truncated) when is_integer(Term) ->
    walk_integer(Term, Budget, Truncated);
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
%% so cutting here really does bound the payload. A cut binary is wrapped in a
%% marker so its prefix is never mistaken for the whole value (e.g. as a key).
walk_bitstring(Bin, Budget, _Truncated) when is_binary(Bin), byte_size(Bin) > Budget ->
    {{?TRUNCATED, binary, binary:part(Bin, 0, Budget), byte_size(Bin)}, 0, true};
walk_bitstring(Bin, Budget, Truncated) when is_binary(Bin) ->
    {Bin, Budget - max(byte_size(Bin), 1), Truncated};
%% A non-byte-aligned bitstring cannot be cut with `binary:part/3', so one
%% over budget is dropped whole.
walk_bitstring(Bits, Budget, _Truncated) when bit_size(Bits) > Budget * 8 ->
    {?TRUNCATED, Budget - 1, true};
walk_bitstring(Bits, Budget, Truncated) ->
    {Bits, Budget - 1, Truncated}.

%% A fixnum is immediate (`flat_size' 0) and stays a flat unit; a bignum is
%% heap-allocated with unbounded digits, so it is charged like a fun below.
walk_integer(Term, Budget, Truncated) ->
    case erts_debug:flat_size(Term) of
        0 ->
            {Term, Budget - 1, Truncated};
        _ ->
            walk_uncuttable(Term, Budget, Truncated)
    end.

%% A fun's free variables and a bignum's digits both ship whole over
%% distribution, so cost is charged by `external_size/1' (the true wire
%% size, unlike `erts_debug:flat_size/1' which skips a captured refc
%% binary's payload) - in full or not at all, since neither can be
%% partially cut the way a binary can.
walk_uncuttable(Term, Budget, Truncated) ->
    Size = erlang:external_size(Term),
    case Size =< Budget of
        true ->
            {Term, Budget - Size, Truncated};
        false ->
            {?TRUNCATED, Budget - 1, true}
    end.

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
%% ETS RECORDS - Match-all / match-spec select / lookup with on-node truncation.
%% =====================================================================
%%
%% Exported functions, not handle_call, so a peek cannot block register
%% or nodedown. The continuation is left opaque.
%% No fixtable — paging is best-effort.

-define(MATCH_ALL, [{'$1', [], ['$1']}]).
%% Resumes a key's rows by offset, so the rest of the key is never shipped as a continuation.
-define(SKIP_CONT, '$voyager_skip').
%% A bag key estimated above this many words is refused instead of copied onto the heap.
-define(LOOKUP_MAX_WORDS, 1_000_000).
-define(KEYED_MAX_ARITY, 255).

-type ets_chunk() ::
    #{records := [term()],
      continuation := term(),
      truncated := boolean(),
      total => non_neg_integer()}.

-spec ets_select_chunk(ets:tab(), pos_integer(), non_neg_integer(), term()) ->
                          {ok, ets_chunk()}.
ets_select_chunk(Table, Limit, Budget, Cont)
    when is_integer(Budget), Budget >= 0, is_integer(Limit), Limit >= 0 ->
    with_bounded_heap(fun() -> do_select(Table, ?MATCH_ALL, Limit, Budget, Cont) end);
ets_select_chunk(_Table, _Limit, _Budget, _Cont) ->
    erlang:error(badarg).

-spec ets_select_spec(ets:tab(), term(), pos_integer(), non_neg_integer(), term()) ->
                         {ok, ets_chunk()}.
ets_select_spec(Table, Spec, Limit, Budget, Cont)
    when is_integer(Budget), Budget >= 0, is_integer(Limit), Limit >= 0 ->
    case valid_spec(Spec) of
        true ->
            with_bounded_heap(fun() -> do_select(Table, Spec, Limit, Budget, Cont) end);
        false ->
            erlang:error(badarg)
    end;
ets_select_spec(_Table, _Spec, _Limit, _Budget, _Cont) ->
    erlang:error(badarg).

-spec ets_lookup(ets:tab(), term(), pos_integer(), non_neg_integer(), term()) ->
                    {ok, ets_chunk()} | {error, key_too_large}.
ets_lookup(Table, Key, Limit, Budget, Cont)
    when is_integer(Budget), Budget >= 0, is_integer(Limit), Limit > 0 ->
    with_bounded_heap(fun() -> do_lookup(Table, Key, Limit, Budget, Cont) end);
ets_lookup(_Table, _Key, _Limit, _Budget, _Cont) ->
    erlang:error(badarg).

%% A bound-key ets:select/3 copies every row of the key into its continuation, so lookup costs no more.
do_lookup(Table, Key, Limit, Budget, undefined) ->
    do_lookup(Table, Key, Limit, Budget, {?SKIP_CONT, 0});
do_lookup(Table, Key, Limit, Budget, {?SKIP_CONT, Skip}) when is_integer(Skip), Skip >= 0 ->
    case oversized_key(Table, Key) of
        true ->
            {error, key_too_large};
        false ->
            Rows = ets:lookup(Table, Key),
            Count = length(Rows),
            Page = lists:sublist(lists:nthtail(min(Skip, Count), Rows), Limit),
            Taken = Skip + length(Page),
            {ok, Chunk} = wrap_records(Page, skip_token(Taken, Count > Taken), Budget),
            {ok, Chunk#{total => Count}}
    end.

%% ets:lookup/2 copies a whole key without yielding; ets:select_count/2 yields and copies nothing.
oversized_key(Table, Key) ->
    Words = ets:info(Table, memory),
    lists:member(ets:info(Table, type), [bag, duplicate_bag]) andalso Words > ?LOOKUP_MAX_WORDS
        andalso key_rows(Table, Key) * Words div max(ets:info(Table, size), 1) > ?LOOKUP_MAX_WORDS.

%% A key-bound head hashes the count to one bucket; a pattern-like key needs one guard clause to stay literal.
key_rows(Table, Key) ->
    Keypos = ets:info(Table, keypos),
    Spec =
        case ms_pattern_key(Key) of
            true ->
                [{'$1', [{'=:=', {element, Keypos, '$1'}, {const, Key}}], [true]}];
            false ->
                [{setelement(Keypos, erlang:make_tuple(N, '_'), Key), [], [true]}
                 || N <- lists:seq(Keypos, ?KEYED_MAX_ARITY)]
        end,
    ets:select_count(Table, Spec).

%% Only '_' and '$<digits>' are variables in a match head, and a map matches any superset.
ms_pattern_key(Key) when is_map(Key); Key =:= '_' ->
    true;
ms_pattern_key(Key) when is_tuple(Key) ->
    ms_pattern_key(tuple_to_list(Key));
ms_pattern_key([Head | Tail]) ->
    ms_pattern_key(Head) orelse ms_pattern_key(Tail);
ms_pattern_key(Key) when is_atom(Key) ->
    case atom_to_list(Key) of
        [$$ | [_ | _] = Digits] -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Digits);
        _ -> false
    end;
ms_pattern_key(_) ->
    false.

skip_token(_Taken, false) ->
    undefined;
skip_token(Taken, true) ->
    {?SKIP_CONT, Taken}.

do_select(Table, Spec, Limit, Budget, undefined) ->
    wrap_select(ets:select(Table, Spec, Limit), Budget);
do_select(_Table, Spec, _Limit, Budget, Cont) ->
    wrap_select(ets:select(
                    ets:repair_continuation(Cont, Spec)),
                Budget).

valid_spec([{_Head, Guards, Body}]) when is_list(Guards), is_list(Body) ->
    true;
valid_spec(_) ->
    false.

wrap_select('$end_of_table', _Budget) ->
    wrap_records([], undefined, 0);
wrap_select({Records, '$end_of_table'}, Budget) when is_list(Records) ->
    wrap_records(Records, undefined, Budget);
wrap_select({Records, Cont}, Budget) when is_list(Records) ->
    wrap_records(Records, Cont, Budget).

wrap_records(Records, Cont, Budget) ->
    {Bounded, Truncated} = bound_records(Records, Budget),
    {ok,
     #{records => Bounded,
       continuation => Cont,
       truncated => Truncated}}.

%% Independent per record: a shared remaining budget would drop rows the continuation already skipped.
bound_records(Records, Budget) ->
    bound_records(Records, Budget, false, []).

bound_records([], _Budget, Truncated, Acc) ->
    {lists:reverse(Acc), Truncated};
bound_records([Record | Rest], Budget, Truncated, Acc) ->
    {Bounded, Cut} = bound_term(Record, Budget),
    bound_records(Rest, Budget, Truncated orelse Cut, [Bounded | Acc]).

%% =====================================================================
%% TRACING - One OTP trace session per trace, owned by an unlinked tracer.
%% =====================================================================

-define(TRACE_FLUSH_MS, 100).
-define(TRACE_BATCH, 200).
%% Budget units held unsent: 200 full-budget events would blow the tracer's `max_heap_size'.
-define(TRACE_BATCH_BUDGET, 400_000).
%% Counts messages, not bytes: a large-args flood on `all' can still peak at GBs.
-define(TRACE_MAX_MAILBOX, 5_000).
%% Below Voyager's 5 s erpc timeout, so the worker gives up (and kills the tracer) first.
-define(TRACE_TIMEOUT, 4_000).
-define(TRACE_MAX_TIME_MS, 3_600_000).
-define(TRACE_MAX_BUDGET, 100_000).
-define(TRACE_MAX_MATCH_SPEC_BYTES, 65_536).
-define(TRACER_TAG, '$voyager_tracer').
-define(TRACE_NAMES_CAP, 1_000).
-define(TRACE_MAX_SESSIONS, 5).
-define(TRACE_MAX_PIDS, 100).
-define(TRACE_MAX_CLAUSES, 10).
-define(TRACE_SPEC_FIELDS,
        [module, function, arity, processes, capture, scope, return_trace, match_spec]).
-define(TRACE_LIMITS, [max_events, max_rate, max_time_ms]).
-define(TRACE_PROCESS_SETS, [all, existing, new]).

-record(tracer,
        {session,
         collector :: pid(),
         limits :: trace_limits(),
         budget :: non_neg_integer(),
         buffer = [] :: [map()],
         buffered = 0 :: non_neg_integer(),
         events = 0 :: non_neg_integer(),
         dropped = 0 :: non_neg_integer(),
         window :: {integer(), non_neg_integer()},
         names = {#{}, #{}} :: {#{pid() => term()}, #{pid() => term()}}}).

-type trace_match_spec() :: [{term(), [term()], [term()]}].
-type trace_spec() ::
    #{module := binary(),
      function := binary() | '_',
      arity := 0..255 | '_',
      processes := all | existing | new | [pid()],
      capture := arity | args,
      scope := local | global,
      return_trace := boolean(),
      match_spec := undefined | trace_match_spec()}.
-type trace_limits() ::
    #{max_events => pos_integer(),
      max_rate => pos_integer(),
      max_time_ms => pos_integer(),
      budget := non_neg_integer()}.

-spec trace_start(pid(), trace_spec(), trace_limits()) -> {ok, pid()} | {error, term()}.
trace_start(Collector, Spec, Limits) when is_pid(Collector) ->
    case trace_validate(Spec, Limits) of
        {ok, Plan} ->
            spawn_tracer(Collector, Plan);
        {error, _} = Error ->
            Error
    end;
trace_start(_Collector, _Spec, _Limits) ->
    {error, {invalid, collector}}.

-spec trace_stop(pid()) -> ok | {error, timeout | not_found}.
trace_stop(Tracer) when is_pid(Tracer), node(Tracer) =:= node() ->
    case erlang:process_info(Tracer, {dictionary, ?TRACER_TAG}) of
        {_, true} ->
            stop_tracer(Tracer);
        _ ->
            {error, not_found}
    end;
trace_stop(_Tracer) ->
    {error, not_found}.

stop_tracer(Tracer) ->
    MRef = erlang:monitor(process, Tracer),
    Tracer ! voyager_trace_stop,
    receive
        {'DOWN', MRef, process, Tracer, noproc} ->
            {error, not_found};
        {'DOWN', MRef, process, Tracer, _Reason} ->
            ok
    after ?TRACE_TIMEOUT ->
        exit(Tracer, kill),
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

-spec trace_sessions() -> non_neg_integer().
trace_sessions() ->
    length(voyager_sessions()).

trace_validate(Spec, Limits) ->
    maybe
        ok ?= first_invalid(?TRACE_SPEC_FIELDS, fun(Field) -> spec_field(Field, Spec) end),
        ok ?= check_limits(Limits),
        #{processes := Processes, scope := Scope, return_trace := ReturnTrace} = Spec,
        {ok, {M, _, _} = MFA} ?= trace_mfa(Spec),
        ok ?= traceable(M, Processes),
        {ok, MatchSpec} ?= trace_match_spec(maps:get(match_spec, Spec), ReturnTrace),
        {ok, {MFA, Scope, MatchSpec, Processes, trace_flags(Spec), Limits}}
    end.

first_invalid(Fields, Valid) ->
    case lists:search(fun(Field) -> not Valid(Field) end, Fields) of
        {value, Field} ->
            {error, {invalid, Field}};
        false ->
            ok
    end.

spec_field(Field, Spec) ->
    case Spec of
        #{Field := Value} ->
            valid_spec_value(Field, Value);
        _ ->
            false
    end.

valid_spec_value(module, Module) ->
    is_binary(Module) andalso Module =/= <<"_">>;
valid_spec_value(function, Function) ->
    is_binary(Function) orelse Function =:= '_';
valid_spec_value(arity, Arity) ->
    Arity =:= '_' orelse is_integer(Arity) andalso Arity >= 0 andalso Arity =< 255;
valid_spec_value(capture, Capture) ->
    Capture =:= arity orelse Capture =:= args;
valid_spec_value(scope, Scope) ->
    Scope =:= local orelse Scope =:= global;
valid_spec_value(return_trace, ReturnTrace) ->
    is_boolean(ReturnTrace);
valid_spec_value(processes, Pids)
    when is_list(Pids), length(Pids) > 0, length(Pids) =< ?TRACE_MAX_PIDS ->
    lists:all(fun(Pid) -> is_pid(Pid) andalso node(Pid) =:= node() end, Pids);
valid_spec_value(processes, ProcessSet) ->
    lists:member(ProcessSet, ?TRACE_PROCESS_SETS);
valid_spec_value(match_spec, undefined) ->
    true;
valid_spec_value(match_spec, MatchSpec)
    when is_list(MatchSpec), length(MatchSpec) > 0, length(MatchSpec) =< ?TRACE_MAX_CLAUSES ->
    erlang:external_size(MatchSpec) =< ?TRACE_MAX_MATCH_SPEC_BYTES
    andalso lists:all(fun({_Head, Guards, Body}) -> is_list(Guards) andalso is_list(Body);
                         (_Clause) -> false
                      end,
                      MatchSpec);
valid_spec_value(_Field, _Value) ->
    false.

check_limits(Limits) ->
    first_invalid([budget | ?TRACE_LIMITS] ++ [limits],
                  fun(Field) -> limit_field(Field, Limits) end).

limit_field(limits, Limits) ->
    lists:any(fun(Key) -> is_map_key(Key, Limits) end, ?TRACE_LIMITS);
limit_field(Field, Limits) ->
    case Limits of
        #{Field := Value} ->
            valid_limit(Field, Value);
        _ ->
            Field =/= budget
    end.

valid_limit(budget, Budget) ->
    is_integer(Budget) andalso Budget >= 0 andalso Budget =< ?TRACE_MAX_BUDGET;
valid_limit(max_time_ms, MaxTime) ->
    is_integer(MaxTime) andalso MaxTime > 0 andalso MaxTime =< ?TRACE_MAX_TIME_MS;
valid_limit(_Field, Limit) ->
    is_integer(Limit) andalso Limit > 0.

%% `trace:function/4' takes '_' only in the rightmost fields: {M, '_', 2} is badarg.
trace_mfa(#{function := '_', arity := Arity}) when Arity =/= '_' ->
    {error, {invalid, arity}};
trace_mfa(#{module := Module, function := Function, arity := Arity}) ->
    try {binary_to_existing_atom(Module), existing_function(Function)} of
        {M, F} ->
            {ok, {M, F, Arity}}
    catch
        error:badarg ->
            {error, unknown_function}
    end.

existing_function('_') ->
    '_';
existing_function(Function) ->
    binary_to_existing_atom(Function).

traceable(Module, Processes) ->
    case {refused(Module, Processes), code:is_loaded(Module)} of
        {true, _} ->
            {error, {refused, Module}};
        {false, false} ->
            {error, {not_loaded, Module}};
        {false, _} ->
            ok
    end.

%% The refusal macros come from `Voyager.Services.Tracer.Refusals.agent_macros/0'.
refused(Module, Pids) when is_list(Pids) ->
    Module =:= ?MODULE orelse lists:member(Module, ?TRACE_ALWAYS_REFUSED);
refused(Module, _ProcessSet) ->
    refused(Module, [])
    orelse lists:member(Module, ?TRACE_HOT)
    orelse lists:any(fun(Prefix) -> lists:prefix(Prefix, atom_to_list(Module)) end,
                     ?TRACE_HOT_PREFIXES).

%% `hot' modules are refused on `all' / `existing' / `new' and allowed on a pid list.
-spec trace_modules() -> [{module(), ok | hot | refused}].
trace_modules() ->
    [{Module, traceability(Module)} || {Module, _} <- code:all_loaded()].

traceability(Module) ->
    case {refused(Module, []), refused(Module, all)} of
        {true, _} ->
            refused;
        {false, true} ->
            hot;
        {false, false} ->
            ok
    end.

%% `erlang:get_module_info/2' never autoloads, unlike `Module:module_info/1' on an unloaded module.
-spec trace_functions(module()) ->
                         {ok, [{atom(), arity(), boolean()}]} | {error, not_loaded}.
trace_functions(Module) when is_atom(Module) ->
    try
        Exported = maps:from_keys(erlang:get_module_info(Module, exports), true),
        {ok,
         [{Name, Arity, is_map_key({Name, Arity}, Exported)}
          || {Name, Arity} <- erlang:get_module_info(Module, functions),
             not generated_function(Name)]}
    catch
        error:badarg ->
            {error, not_loaded}
    end.

%% Funs and inlined helpers compile to names like `-handle_call/3-fun-0-'.
generated_function(Name) ->
    case atom_to_binary(Name) of
        <<"-", _/binary>> ->
            true;
        _ ->
            false
    end.

%% Atoms in a match spec are created on the remote when the dist message is decoded.
trace_match_spec(undefined, ReturnTrace) ->
    {ok, [{'_', [], return_body(ReturnTrace)}]};
trace_match_spec(MatchSpec, ReturnTrace) ->
    maybe
        false ?= refused_action([{Guards, Body} || {_Head, Guards, Body} <- MatchSpec],
                                refused_actions(ReturnTrace)),
        %% `match_spec_test' runs the body here (`enable_trace' segfaults); `false' keeps it compile-only.
        {ok, _, _, _} ?=
            erlang:match_spec_test([], [{H, [false | G], B} || {H, G, B} <- MatchSpec], trace),
        {ok,
         [{Head, Guards, Body ++ return_body(ReturnTrace)} || {Head, Guards, Body} <- MatchSpec]}
    else
        {value, Action} ->
            {error, {refused_action, Action}};
        {error, Errors} ->
            {error, {invalid_match_spec, Errors}}
    end.

%% `exception_trace' also closes a frame on a raise, so a call never stays open in Voyager.
return_body(true) ->
    [{exception_trace}];
return_body(false) ->
    [].

%% With `exception_trace', silenced calls grow a tail-recursive loop's stack and no limit fires.
refused_actions(true) ->
    [message | ?TRACE_REFUSED_ACTIONS];
refused_actions(false) ->
    ?TRACE_REFUSED_ACTIONS.

refused_action(Term, Refused) when is_tuple(Term), tuple_size(Term) > 0 ->
    case lists:member(element(1, Term), Refused) of
        true ->
            {value, element(1, Term)};
        false ->
            refused_action(tuple_to_list(Term), Refused)
    end;
refused_action([Head | Tail], Refused) ->
    case refused_action(Head, Refused) of
        false ->
            refused_action(Tail, Refused);
        Found ->
            Found
    end;
refused_action(Term, Refused) when is_map(Term) ->
    refused_action(maps:to_list(Term), Refused);
refused_action(_Term, _Refused) ->
    false.

trace_flags(#{capture := arity}) ->
    [call, arity, monotonic_timestamp];
trace_flags(#{capture := args}) ->
    [call, monotonic_timestamp].

spawn_tracer(Collector, Plan) ->
    Caller = self(),
    Ref = make_ref(),
    {Pid, MRef} =
        spawn_opt(fun() -> tracer_init(Caller, Ref, Collector, Plan) end,
                  [monitor,
                   {priority, high},
                   %% Traced processes enqueue without taking the tracer's main lock, and a full
                   %% mailbox stops the trace via `mailbox_limit' instead of a heap-limit kill.
                   {message_queue_data, off_heap},
                   {max_heap_size,
                    #{size => 10_000_000,
                      kill => true,
                      error_logger => true}}]),
    receive
        {Ref, Reply} ->
            erlang:demonitor(MRef, [flush]),
            Reply;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {tracer_down, Reason}}
    after ?TRACE_TIMEOUT ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

%% A tracer that dies takes its session with it, so only clean failures need a destroy.
tracer_init(Caller, Ref, Collector, {_, _, _, Processes, _, Limits} = Plan) ->
    put(?TRACER_TAG, true),
    Session = trace:session_create(session_name(Processes), self(), []),
    case tracer_install(Session, Plan) of
        ok ->
            erlang:monitor(process, Collector),
            MaxTime = maps:get(max_time_ms, Limits, ?TRACE_MAX_TIME_MS),
            erlang:send_after(MaxTime, self(), voyager_trace_ttl),
            erlang:send_after(?TRACE_FLUSH_MS, self(), voyager_trace_flush),
            Caller ! {Ref, {ok, self()}},
            tracer_loop(#tracer{session = Session,
                                collector = Collector,
                                limits = Limits,
                                budget = maps:get(budget, Limits),
                                window = {erlang:monotonic_time(millisecond), 0}});
        {error, _} = Error ->
            trace:session_destroy(Session),
            Caller ! {Ref, Error}
    end.

session_name(Pids) when is_list(Pids) ->
    voyager;
session_name(_ProcessSet) ->
    voyager_all.

tracer_install(Session, {MFA, Scope, MatchSpec, Processes, Flags, _Limits}) ->
    maybe
        ok ?= session_cap(),
        ok ?= trace_function(Session, MFA, MatchSpec, Scope),
        trace_processes(Session, Processes, Flags)
    end.

%% The session exists before this count, so racers for the last slot can both lose, never both win.
session_cap() ->
    Sessions = voyager_sessions(),
    case {length(Sessions), length([all || voyager_all <- Sessions])} of
        {Total, _} when Total > ?TRACE_MAX_SESSIONS ->
            {error, too_many_sessions};
        {_, All} when All > 1 ->
            {error, all_processes_busy};
        _ ->
            ok
    end.

voyager_sessions() ->
    [Name || {Name, _} <- trace:session_info(all), Name =:= voyager orelse Name =:= voyager_all].

trace_function(Session, MFA, MatchSpec, Scope) ->
    case trace:function(Session, MFA, MatchSpec, [Scope]) of
        0 ->
            {error, no_function_matched};
        _ ->
            ok
    end.

trace_processes(_Session, [], _Flags) ->
    ok;
trace_processes(Session, [Pid | Rest], Flags) ->
    try trace:process(Session, Pid, true, Flags) of
        _ ->
            trace_processes(Session, Rest, Flags)
    catch
        error:badarg ->
            {error, {noproc, Pid}}
    end;
trace_processes(Session, ProcessSet, Flags) ->
    trace:process(Session, ProcessSet, true, Flags),
    %% `all' and `existing' include this process, and a tracer tracing itself gets no messages.
    trace:process(Session, self(), false, [all]),
    ok.

%% `max_heap_size' does not count an off-heap mailbox, so the tracer checks its own queue.
tracer_loop(T) ->
    case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, Len} when Len > ?TRACE_MAX_MAILBOX ->
            tracer_stop(T#tracer{dropped = T#tracer.dropped + Len}, mailbox_limit);
        _ ->
            tracer_receive(T)
    end.

tracer_receive(#tracer{budget = Budget} = T) ->
    receive
        {trace_ts, Pid, call, MFA, Ts} ->
            tracer_event(T, Pid, Ts, call_event(MFA, Budget));
        {trace_ts, Pid, call, MFA, Message, Ts} ->
            {CallMFA, Event} = call_event(MFA, Budget),
            tracer_event(T, Pid, Ts, {CallMFA, with_message(Event, Message, Budget)});
        {trace_ts, Pid, return_from, MFA, Value, Ts} ->
            tracer_event(T, Pid, Ts, {MFA, value_event(return, Value, Budget)});
        {trace_ts, Pid, exception_from, MFA, Value, Ts} ->
            tracer_event(T, Pid, Ts, {MFA, value_event(exception, Value, Budget)});
        voyager_trace_flush ->
            erlang:send_after(?TRACE_FLUSH_MS, self(), voyager_trace_flush),
            tracer_loop(send_batch(T));
        voyager_trace_ttl ->
            tracer_stop(T, time_limit);
        voyager_trace_stop ->
            tracer_stop(T, stopped);
        {'DOWN', _MRef, process, _Collector, _Reason} ->
            trace:session_destroy(T#tracer.session);
        _Other ->
            tracer_loop(T)
    end.

call_event({M, F, Args}, Budget) when is_list(Args) ->
    {Bounded, Truncated} = bound_term(Args, Budget),
    {{M, F, length(Args)}, #{type => call, args => Bounded, truncated => Truncated}};
call_event(MFA, _Budget) ->
    {MFA, #{type => call}}.

with_message(Event, Message, Budget) ->
    {Bounded, Truncated} = bound_term(Message, Budget),
    Event#{message => Bounded, truncated => Truncated orelse maps:get(truncated, Event, false)}.

value_event(Type, Value, Budget) ->
    {Bounded, Truncated} = bound_term(Value, Budget),
    #{type => Type, value => Bounded, truncated => Truncated}.

tracer_event(#tracer{limits = Limits} = T0, Pid, Ts, {MFA, Event}) ->
    {Window, Rate} = tick(T0#tracer.window),
    {Label, Names} = process_label(Pid, T0#tracer.names),
    At = erlang:convert_time_unit(Ts, nanosecond, microsecond) + erlang:time_offset(microsecond),
    T = T0#tracer{buffer =
                      [Event#{pid => Pid, process => Label, mfa => MFA, at => At}
                       | T0#tracer.buffer],
                  buffered = T0#tracer.buffered + 1,
                  events = T0#tracer.events + 1,
                  window = Window,
                  names = Names},
    MaxEvents = maps:get(max_events, Limits, undefined),
    MaxRate = maps:get(max_rate, Limits, undefined),
    if
        is_integer(MaxEvents), T#tracer.events >= MaxEvents ->
            tracer_stop(T, event_limit);
        is_integer(MaxRate), Rate > MaxRate ->
            tracer_stop(T, rate_limit);
        T#tracer.buffered >= min(?TRACE_BATCH, ?TRACE_BATCH_BUDGET div max(T#tracer.budget, 1)) ->
            tracer_loop(send_batch(T));
        true ->
            tracer_loop(T)
    end.

tick({Start, Count}) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Start >= 1_000 of
        true ->
            {{Now, 1}, 1};
        false ->
            {{Start, Count + 1}, Count + 1}
    end.

process_label(Pid, {Current, Previous} = Names) ->
    case {Current, Previous} of
        {#{Pid := Label}, _} ->
            {Label, Names};
        {_, #{Pid := Label}} ->
            {Label, remember_label(Pid, Label, Names)};
        _ ->
            Label = lookup_label(Pid),
            {Label, remember_label(Pid, Label, Names)}
    end.

%% Two generations: callers seen since the last rotation survive it, cold and dead ones age out.
remember_label(Pid, Label, {Current, _Previous}) when map_size(Current) >= ?TRACE_NAMES_CAP div 2 ->
    {#{Pid => Label}, Current};
remember_label(Pid, Label, {Current, Previous}) ->
    {Current#{Pid => Label}, Previous}.

lookup_label(Pid) ->
    case erlang:process_info(Pid, [registered_name, {dictionary, '$initial_call'}, initial_call])
    of
        undefined ->
            undefined;
        [{registered_name, Name}, _, _] when is_atom(Name) ->
            Name;
        [_, {_, {_, _, _} = InitialCall}, _] ->
            InitialCall;
        [_, _, {initial_call, InitialCall}] ->
            InitialCall
    end.

%% `nosuspend': a busy dist link drops the batch instead of blocking the draining tracer.
send_batch(#tracer{buffer = []} = T) ->
    T;
send_batch(#tracer{collector = Collector,
                   buffer = Buffer,
                   buffered = Buffered,
                   dropped = Dropped} =
               T) ->
    Batch = {voyager_trace_events, self(), lists:reverse(Buffer), Dropped},
    case erlang:send(Collector, Batch, [nosuspend, noconnect]) of
        ok ->
            T#tracer{buffer = [], buffered = 0};
        _ ->
            T#tracer{buffer = [],
                     buffered = 0,
                     dropped = Dropped + Buffered}
    end.

tracer_stop(#tracer{session = Session, collector = Collector} = T0, Reason) ->
    trace:session_destroy(Session),
    #tracer{events = Events, dropped = Dropped} = send_batch(T0),
    erlang:send(Collector,
                {voyager_trace_done, self(), Reason, #{events => Events, dropped => Dropped}},
                [noconnect]),
    ok.

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
