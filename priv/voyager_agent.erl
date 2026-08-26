-module(voyager_agent).

-export([proc_top/3, proc_top/4, proc_top/5]).

%% @equiv proc_top(Attrs, SortBy, Limit, desc, undefined)
-spec proc_top([atom()], atom(), pos_integer()) -> [map()].
proc_top(Attrs, SortBy, Limit) ->
    proc_top(Attrs, SortBy, Limit, desc, undefined).

%% @equiv proc_top(Attrs, SortBy, Limit, Direction, undefined)
-spec proc_top([atom()], atom(), pos_integer(), asc | desc) -> [map()].
proc_top(Attrs, SortBy, Limit, Direction) ->
    proc_top(Attrs, SortBy, Limit, Direction, undefined).

%% @doc Returns the top `Limit' processes sorted by `SortBy' in `Direction'
%% (`desc' keeps the largest, `asc' the smallest) and number of all processes.
%%
%% Runs on the remote node (shipped via the agent). Walks the process table
%% with an iterator and keeps only the running top-`Limit' in memory, so peak
%% memory is bounded by `Limit' rather than the process count. The transient
%% erpc worker is guarded with a `max_heap_size' flag so a pathological scan
%% kills the worker instead of the node, and only the top-`Limit' rows cross
%% the wire.
%%
%% Each returned entry is a map of the requested `Attrs' plus `pid'. `SortBy'
%% must be one of `Attrs' and resolve to an integer; processes missing it (or
%% that died mid-scan) are skipped.
%%
%% `Search' filters the population before ranking: `undefined' (or an empty
%% string) applies no filter, otherwise only processes whose `pid' or any
%% requested non-numeric attribute contains `Search' (case-insensitive
%% substring) are considered. Numeric attributes are never searched. The needle
%% is lowercased once; matching is per-process and only pays its cost when a
%% search is active.
-spec proc_top([atom()], atom(), pos_integer(), asc | desc, undefined | iodata()) ->
                  [map()].
proc_top(Attrs, SortBy, Limit, Direction, Search) ->
    %% ~4MB on 64-bit;
    process_flag(max_heap_size,
                 #{size => 500000,
                   kill => true,
                   error_logger => true}),
    Top = fold(iterator(), Attrs, SortBy, Limit, Direction, needle(Search), [], 0),
    %% `Top' keeps the eviction candidate ("worst kept") at the head, so
    %% reversing always yields best-to-worst in the requested direction.
    {[to_map(Entry) || Entry <- lists:reverse(Top)], erlang:system_info(process_count)}.

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

fold(State, Attrs, SortBy, Limit, Direction, Needle, Top, Size) ->
    case next(State) of
        {Pid, NextState} ->
            {NewTop, NewSize} =
                maybe_insert(Pid, Attrs, SortBy, Limit, Direction, Needle, Top, Size),
            fold(NextState, Attrs, SortBy, Limit, Direction, Needle, NewTop, NewSize);
        none ->
            Top
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

%% `Top' is kept with the "worst kept" entry at the head (the smallest for
%% `desc', the largest for `asc'), so it is the O(1) admission threshold once
%% we are at capacity.
insert(_Top, _Size, Limit, _Direction, _Value, _Pid, _Info) when Limit =< 0 ->
    {[], 0};
insert(Top, Size, Limit, Direction, Value, Pid, Info) when Size < Limit ->
    {insert_sorted(Top, Direction, Value, Pid, Info), Size + 1};
insert([{WorstValue, _, _} | Rest] = Top, Size, _Limit, Direction, Value, Pid, Info) ->
    case better(Direction, Value, WorstValue) of
        true ->
            {insert_sorted(Rest, Direction, Value, Pid, Info), Size};
        false ->
            {Top, Size}
    end.

%% Keeps the list ordered worst-first: ascending for `desc' (min at head),
%% descending for `asc' (max at head).
insert_sorted([{V, _, _} = Entry | Rest], desc, Value, Pid, Info) when Value > V ->
    [Entry | insert_sorted(Rest, desc, Value, Pid, Info)];
insert_sorted([{V, _, _} = Entry | Rest], asc, Value, Pid, Info) when Value < V ->
    [Entry | insert_sorted(Rest, asc, Value, Pid, Info)];
insert_sorted(Rest, _Direction, Value, Pid, Info) ->
    [{Value, Pid, Info} | Rest].

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
    case string:lowercase(unicode:characters_to_binary(Search)) of
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

to_map({_Value, Pid, Info}) ->
    maps:from_list([{pid, Pid} | Info]).
