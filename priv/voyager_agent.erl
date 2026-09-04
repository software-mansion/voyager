-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([proc_top/5]).
-export([ets_select_chunk/3, ets_lookup/2, truncate_term/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).


-record(state, {nodes = #{} :: #{node() => true}}).

-type state() :: #state{nodes :: #{node() => true}}.

%% =====================================================================
%% REGISTER - Adds the Voyager node to the watched set and returns the server pid.
%% =====================================================================

%% Bounds the start/register retry so a node whose agent keeps stopping
%% cannot spin here forever.
-define(MAX_REGISTER_ATTEMPTS, 3).

-define(ETS_MAX_HEAP_SIZE, 500_000).
-define(ETS_CHUNK_SIZES, [10, 20, 50]).
-define(MATCH_ALL, [{'$1', [], ['$1']}]).
-define(MAX_BINARY_BYTES, 512).
-define(MAX_COLLECTION, 50).
-define(MAX_DEPTH, 5).
-define(MARKER, '$voyager_truncated').

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

%% @doc Returns `{Entries, TotalCount}': the top `Limit' processes by `SortBy'
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
%% ETS RECORDS - Match-all select / lookup with on-node truncation.
%% =====================================================================
%%
%% Exported functions, not handle_call, so a peek cannot block register
%% or nodedown. A one-shot worker with a 500_000-word heap cap does the
%% ETS read and truncates records; the continuation is left opaque.
%% No fixtable — paging is best-effort.

-spec ets_select_chunk(ets:tab(), pos_integer(), term()) ->
                          '$end_of_table' | {[term()], term()}.
ets_select_chunk(Table, Limit, Cont) ->
    case lists:member(Limit, ?ETS_CHUNK_SIZES) of
        true ->
            isolated(fun() -> do_select(Table, Limit, Cont) end);
        false ->
            erlang:error(badarg)
    end.

-spec ets_lookup(ets:tab(), term()) -> [term()].
ets_lookup(Table, Key) ->
    isolated(fun() -> truncate_records(ets:lookup(Table, Key)) end).

%% Same caps as Voyager.Services.Ets.Sanitize (512 / 50 / 5). Not a
%% visit-budget truncator: oversized binaries keep a prefix, collections
%% keep 50 elements, nesting stops at depth 5.
-spec truncate_term(term()) -> term().
truncate_term(Term) ->
    sanitize(Term, 0).

do_select(Table, Limit, undefined) ->
    truncate_select(ets:select(Table, ?MATCH_ALL, Limit));
do_select(_Table, _Limit, Cont) ->
    %% Continuation has typically crossed to Voyager and back.
    truncate_select(ets:select(ets:repair_continuation(Cont, ?MATCH_ALL))).

truncate_select('$end_of_table') ->
    '$end_of_table';
truncate_select({Records, Cont}) when is_list(Records) ->
    {truncate_records(Records), Cont}.

truncate_records(Records) ->
    [truncate_term(R) || R <- Records].

%% Link so an erpc timeout (killing this process) also kills the worker.
%% trap_exit so a heap kill can be turned into error:killed instead of
%% taking this process down before the caller sees a mapped error.
isolated(Fun) ->
    OldTrap = process_flag(trap_exit, true),
    try
        isolated_wait(Fun)
    after
        process_flag(trap_exit, OldTrap)
    end.

isolated_wait(Fun) ->
    Parent = self(),
    {Pid, MRef} = spawn_opt(fun() -> isolated_worker(Parent, Fun) end, [link, monitor]),
    receive
        {Pid, {ok, Result}} ->
            demonitor(MRef, [flush]),
            flush_exit(Pid),
            Result;
        {Pid, {caught, Kind, Reason, Stack}} ->
            demonitor(MRef, [flush]),
            flush_exit(Pid),
            erlang:raise(Kind, Reason, Stack);
        {'DOWN', MRef, process, Pid, Reason} ->
            flush_exit(Pid),
            isolated_down(Reason);
        {'EXIT', Pid, Reason} ->
            receive
                {'DOWN', MRef, process, Pid, _} ->
                    ok
            after 0 ->
                ok
            end,
            isolated_down(Reason)
    end.

isolated_worker(Parent, Fun) ->
    process_flag(max_heap_size,
                 #{size => ?ETS_MAX_HEAP_SIZE,
                   kill => true,
                   error_logger => true}),
    try Fun() of
        Result ->
            Parent ! {self(), {ok, Result}}
    catch
        Kind:Reason:Stack ->
            Parent ! {self(), {caught, Kind, Reason, Stack}}
    end.

isolated_down(killed) ->
    erlang:error(killed);
isolated_down({killed, _Info}) ->
    erlang:error(killed);
isolated_down(Reason) ->
    exit(Reason).

flush_exit(Pid) ->
    receive
        {'EXIT', Pid, _} ->
            ok
    after 0 ->
        ok
    end.

sanitize({?MARKER, depth}, _Depth) ->
    {?MARKER, depth};
sanitize({?MARKER, Kind, _Payload, _Meta}, Depth)
    when (Kind =:= list orelse Kind =:= map orelse Kind =:= tuple), Depth >= ?MAX_DEPTH ->
    {?MARKER, depth};
sanitize({?MARKER, binary, Prefix, Size}, _Depth)
    when is_binary(Prefix), is_integer(Size), Size >= 0 ->
    {?MARKER, binary, cap_binary(Prefix), max(Size, byte_size(Prefix))};
sanitize({?MARKER, Kind, Elements, Omitted}, Depth)
    when (Kind =:= list orelse Kind =:= map orelse Kind =:= tuple), is_list(Elements),
         is_integer(Omitted), Omitted >= 0 ->
    sanitize_collection_marker(Kind, Elements, Omitted, Depth);
sanitize([], Depth) when Depth >= ?MAX_DEPTH ->
    [];
sanitize(Map, Depth) when is_map(Map), map_size(Map) =:= 0, Depth >= ?MAX_DEPTH ->
    Map;
sanitize({}, Depth) when Depth >= ?MAX_DEPTH ->
    {};
sanitize(Term, Depth)
    when (is_list(Term) orelse is_map(Term) orelse is_tuple(Term)), Depth >= ?MAX_DEPTH ->
    {?MARKER, depth};
sanitize(Term, Depth) ->
    sanitize_value(Term, Depth).

sanitize_value(Bin, _Depth) when is_binary(Bin) ->
    Size = byte_size(Bin),
    case Size > ?MAX_BINARY_BYTES of
        true ->
            {?MARKER, binary, cap_binary(Bin), Size};
        false ->
            Bin
    end;
sanitize_value(Bits, _Depth) when is_bitstring(Bits), not is_binary(Bits) ->
    Pad = 8 - bit_size(Bits) rem 8,
    Padded = <<Bits/bitstring, 0:Pad>>,
    {?MARKER, binary, cap_binary(Padded), byte_size(Padded)};
sanitize_value(List, Depth) when is_list(List) ->
    {Taken, Rest} = take_cons(List, ?MAX_COLLECTION),
    Sanitized = [sanitize(E, Depth + 1) || E <- Taken],
    if Rest =:= [] ->
           Sanitized;
       is_list(Rest) ->
           {?MARKER, list, Sanitized, cons_count(Rest)};
       true ->
           cons(Sanitized, sanitize(Rest, Depth + 1))
    end;
sanitize_value(Map, Depth) when is_map(Map) ->
    Pairs = take_map_pairs(Map),
    Omitted = max(map_size(Map) - length(Pairs), 0),
    SanitizedPairs = [{sanitize(K, Depth + 1), sanitize(V, Depth + 1)} || {K, V} <- Pairs],
    rebuild_map(SanitizedPairs, Omitted);
sanitize_value(Tuple, Depth) when is_tuple(Tuple) ->
    Size = tuple_size(Tuple),
    Kept = min(Size, ?MAX_COLLECTION),
    Sanitized = [sanitize(element(I, Tuple), Depth + 1) || I <- lists:seq(1, Kept)],
    case Size > ?MAX_COLLECTION of
        true ->
            {?MARKER, tuple, Sanitized, Size - ?MAX_COLLECTION};
        false ->
            list_to_tuple(Sanitized)
    end;
sanitize_value(Term, _Depth) ->
    Term.

sanitize_collection_marker(Kind, Elements, Omitted, Depth) ->
    {Taken, Rest} = take_cons(Elements, ?MAX_COLLECTION),
    Sanitized =
        case Kind of
            map ->
                [sanitize_map_pair(Pair, Depth) || Pair <- Taken];
            _ ->
                [sanitize(E, Depth + 1) || E <- Taken]
        end,
    {?MARKER, Kind, Sanitized, Omitted + leftover_count(Rest)}.

sanitize_map_pair({Key, Value}, Depth) ->
    {sanitize(Key, Depth + 1), sanitize(Value, Depth + 1)};
sanitize_map_pair(Other, Depth) ->
    sanitize(Other, Depth + 1).

cap_binary(Bin) when is_binary(Bin) ->
    Kept =
        case byte_size(Bin) > ?MAX_BINARY_BYTES of
            true ->
                binary:part(Bin, 0, ?MAX_BINARY_BYTES);
            false ->
                Bin
        end,
    binary:copy(Kept).

leftover_count(Rest) when is_list(Rest) ->
    cons_count(Rest);
leftover_count(_ImproperTail) ->
    1.

rebuild_map(Pairs, 0) ->
    AsMap = maps:from_list(Pairs),
    case map_size(AsMap) =:= length(Pairs) of
        true ->
            AsMap;
        false ->
            {?MARKER, map, Pairs, 0}
    end;
rebuild_map(Pairs, Omitted) ->
    {?MARKER, map, Pairs, Omitted}.

cons(Heads, Tail) ->
    lists:foldr(fun(Head, Acc) -> [Head | Acc] end, Tail, Heads).

take_cons(List, N) ->
    take_cons(List, N, []).

take_cons(List, N, Acc) when N > 0, is_list(List), List =/= [] ->
    [Head | Tail] = List,
    take_cons(Tail, N - 1, [Head | Acc]);
take_cons(Rest, _N, Acc) ->
    {lists:reverse(Acc), Rest}.

cons_count(List) ->
    cons_count(List, 0).

cons_count([_Head | Tail], Acc) ->
    cons_count(Tail, Acc + 1);
cons_count([], Acc) ->
    Acc;
cons_count(_ImproperTail, Acc) ->
    Acc + 1.

%% Do not maps:to_list a huge map. OTP 26+ `iterator/2` `ordered` matches
%% Elixir's sort-then-take-50; older `iterator/1` keeps an arbitrary 50
%% the host cannot repair. Runtime export check, not `-if(?OTP_RELEASE)`.
take_map_pairs(Map) ->
    take_map_pairs(maps:next(map_iter(Map)), ?MAX_COLLECTION, []).

take_map_pairs(none, _Left, Acc) ->
    lists:reverse(Acc);
take_map_pairs(_Next, 0, Acc) ->
    lists:reverse(Acc);
take_map_pairs({K, V, Iter}, Left, Acc) ->
    take_map_pairs(maps:next(Iter), Left - 1, [{K, V} | Acc]).

map_iter(Map) ->
    case erlang:function_exported(maps, iterator, 2) of
        true ->
            maps:iterator(Map, ordered);
        false ->
            maps:iterator(Map)
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

