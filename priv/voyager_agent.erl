-module(voyager_agent).

-export([proc_top/3, proc_top/4]).

%% @equiv proc_top(Attrs, SortBy, Limit, desc)
-spec proc_top([atom()], atom(), pos_integer()) -> [map()].
proc_top(Attrs, SortBy, Limit) ->
    proc_top(Attrs, SortBy, Limit, desc).

%% @doc Returns the top `Limit' processes sorted by `SortBy' in `Direction'
%% (`desc' keeps the largest, `asc' the smallest).
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
-spec proc_top([atom()], atom(), pos_integer(), asc | desc) -> [map()].
proc_top(Attrs, SortBy, Limit, Direction) ->
    %% ~4MB on 64-bit;
    process_flag(max_heap_size,
                 #{size => 500000,
                   kill => true,
                   error_logger => true}),
    Top = fold(iterator(), Attrs, SortBy, Limit, Direction, [], 0),
    %% `Top' keeps the eviction candidate ("worst kept") at the head, so
    %% reversing always yields best-to-worst in the requested direction.
    [to_map(Entry) || Entry <- lists:reverse(Top)].

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

fold(State, Attrs, SortBy, Limit, Direction, Top, Size) ->
    case next(State) of
        {Pid, NextState} ->
            {NewTop, NewSize} = maybe_insert(Pid, Attrs, SortBy, Limit, Direction, Top, Size),
            fold(NextState, Attrs, SortBy, Limit, Direction, NewTop, NewSize);
        none ->
            Top
    end.

maybe_insert(Pid, Attrs, SortBy, Limit, Direction, Top, Size) ->
    case erlang:process_info(Pid, Attrs) of
        Info when is_list(Info) ->
            case value(SortBy, Info) of
                Value when is_integer(Value) ->
                    insert(Top, Size, Limit, Direction, Value, Pid, Info);
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

to_map({_Value, Pid, Info}) ->
    maps:from_list([{pid, Pid} | Info]).
