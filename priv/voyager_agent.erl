-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([proc_top/5]).
-export([proc_links/2, proc_monitors/2, proc_monitored_by/2, proc_dictionary/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export_type([bounded/1, monitor/0, dict_entry/0]).

-record(state, {nodes = #{} :: #{node() => true}}).

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
%% Process info API
%% ========================================================================

%% A truncated view of an unbounded attribute. `total' is the real length on the
%% remote, `items' holds at most `Limit' entries, and `truncated' says whether
%% anything was dropped - so callers can surface the gap instead of silently
%% showing a partial list as if it were complete.
-type bounded(Item) ::
    #{total := non_neg_integer(),
      truncated := boolean(),
      items := [Item]}.
-type monitor() :: {process, pid() | {atom(), node()}} | {port, port()} | term().
-type dict_entry() :: {term(), term()}.

%% Links and monitors are returned as raw terms - they are needed as identifiers
%% (navigating to a process), and only their length is unbounded, which `Limit'
%% caps on the remote.
-spec proc_links(pid(), non_neg_integer()) ->
                    {ok, bounded(pid() | port())} | {error, dead}.
proc_links(Pid, Limit) ->
    bounded_attribute(Pid, links, Limit).

-spec proc_monitors(pid(), non_neg_integer()) -> {ok, bounded(monitor())} | {error, dead}.
proc_monitors(Pid, Limit) ->
    bounded_attribute(Pid, monitors, Limit).

-spec proc_monitored_by(pid(), non_neg_integer()) ->
                           {ok, bounded(pid() | port())} | {error, dead}.
proc_monitored_by(Pid, Limit) ->
    bounded_attribute(Pid, monitored_by, Limit).

%% Entries are shipped as raw `{Key, Value}' terms. Only the entry count is
%% capped here (`Limit'); an individual term can still be large, which the
%% `max_heap_size' cap in `with_bounded_heap/1' is there to survive.
-spec proc_dictionary(pid(), non_neg_integer()) ->
                         {ok, bounded(dict_entry())} | {error, dead}.
proc_dictionary(Pid, Limit) ->
    bounded_attribute(Pid, dictionary, Limit).

-spec bounded_attribute(pid(),
                        links | monitors | monitored_by | dictionary,
                        non_neg_integer()) ->
                           {ok, bounded(term())} | {error, dead}.
bounded_attribute(Pid, Key, Limit) when is_pid(Pid), is_integer(Limit), Limit >= 0 ->
    with_bounded_heap(fun() -> do_bounded_attribute(Pid, Key, Limit) end).

-spec do_bounded_attribute(pid(),
                           links | monitors | monitored_by | dictionary,
                           non_neg_integer()) ->
                              {ok, bounded(term())} | {error, dead}.
do_bounded_attribute(Pid, Key, Limit) ->
    case erlang:process_info(Pid, Key) of
        undefined ->
            {error, dead};
        {Key, Items} when is_list(Items) ->
            {ok, bounded(length(Items), Limit, lists:sublist(Items, Limit))}
    end.

%% =====================================================================
%% HELPERS
%% =====================================================================

-spec bounded(non_neg_integer(), non_neg_integer(), [term()]) -> bounded(term()).
bounded(Total, Limit, Items) ->
    #{total => Total,
      truncated => Total > Limit,
      items => Items}.

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
