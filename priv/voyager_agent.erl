-module(voyager_agent).

-export([proc_top/3]).

%% @doc Returns the top `Limit' processes sorted by `SortBy' (descending).
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
-spec proc_top([atom()], atom(), pos_integer()) -> [map()].
proc_top(Attrs, SortBy, Limit) ->
    %% ~4MB on 64-bit; kill this worker (not the node) if it blows up.
    process_flag(max_heap_size,
                 #{size => 500000,
                   kill => true,
                   error_logger => true}),
    Top = fold(iterator(), Attrs, SortBy, Limit, [], 0),
    %% `Top' is ascending by sort value; emit descending as maps.
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

fold(State, Attrs, SortBy, Limit, Top, Size) ->
    case next(State) of
        {Pid, NextState} ->
            {NewTop, NewSize} = maybe_insert(Pid, Attrs, SortBy, Limit, Top, Size),
            fold(NextState, Attrs, SortBy, Limit, NewTop, NewSize);
        none ->
            Top
    end.

maybe_insert(Pid, Attrs, SortBy, Limit, Top, Size) ->
    case erlang:process_info(Pid, Attrs) of
        Info when is_list(Info) ->
            case value(SortBy, Info) of
                Value when is_integer(Value) ->
                    insert(Top, Size, Limit, Value, Pid, Info);
                _ ->
                    {Top, Size}
            end;
        _ ->
            {Top, Size}
    end.

%% `Top' is kept ascending by sort value, so the smallest kept value is at the
%% head and acts as the O(1) admission threshold once we are at capacity.
insert(_Top, _Size, Limit, _Value, _Pid, _Info) when Limit =< 0 ->
    {[], 0};
insert(Top, Size, Limit, Value, Pid, Info) when Size < Limit ->
    {insert_sorted(Top, Value, Pid, Info), Size + 1};
insert([{MinValue, _, _} | _] = Top, Size, _Limit, Value, _Pid, _Info)
    when Value =< MinValue ->
    {Top, Size};
insert([_Min | Rest], Size, _Limit, Value, Pid, Info) ->
    {insert_sorted(Rest, Value, Pid, Info), Size}.

insert_sorted([{V, _, _} = Entry | Rest], Value, Pid, Info) when Value > V ->
    [Entry | insert_sorted(Rest, Value, Pid, Info)];
insert_sorted(Rest, Value, Pid, Info) ->
    [{Value, Pid, Info} | Rest].

value(SortBy, Info) ->
    case lists:keyfind(SortBy, 1, Info) of
        {SortBy, Value} ->
            Value;
        false ->
            undefined
    end.

to_map({_Value, Pid, Info}) ->
    maps:from_list([{pid, Pid} | Info]).
