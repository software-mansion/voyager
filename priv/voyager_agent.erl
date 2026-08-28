-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([ping/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Bounds the start/register retry so a node whose agent keeps stopping
%% cannot spin here forever.
-define(REGISTER_ATTEMPTS, 3).

%% Voyager nodes currently attached. The agent stops and purges
%% its own code when this map becomes empty (last ParentNode is gone).
-record(state, {nodes = #{} :: #{node() => true}}).

-type state() :: #state{nodes :: #{node() => true}}.

%% =====================================================================
%% REGISTER - Adds the parent to the list of nodes and returns the server pid.
%% %% =====================================================================

%% Adds the parent to the list of nodes and returns the server pid.
%% If the server is not running, it starts it and registers the parent.
%% Uses `gen_server:start/4` so the process outlives the transient erpc caller.
%% This function can crash if the `init/1` function fails.
-spec register(node()) -> {ok, pid()} | {error, term()}.
register(ParentNode) when is_atom(ParentNode) ->
    do_start(ParentNode, ?REGISTER_ATTEMPTS).

-spec do_start(node(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
do_start(_ParentNode, 0) ->
    {error, unavailable};
do_start(ParentNode, Attempts) ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, ParentNode, []) of
                {ok, Pid} ->
                    {ok, Pid};
                {error, {already_started, _Pid}} ->
                    do_register(ParentNode, Attempts);
                _Error ->
                    %% terminate/2 is not called when init/1 fails, so unload here or the
                    %% module stays loaded on the node after a failed register/1.
                    %% it purges the code so this return value is ignored.
                    purge_code()
            end;
        _Pid ->
            do_register(ParentNode, Attempts)
    end.

%% The agent stops itself when its last parent goes down, so it can be gone
%% between `whereis/1` above and this call. That exits with `noproc`, so retry
%% the whole start/register sequence instead of letting the exit escape.
-spec do_register(node(), pos_integer()) -> {ok, pid()} | {error, term()}.
do_register(ParentNode, Attempts) ->
    try gen_server:call(?MODULE, {register, ParentNode}) of
        {ok, Pid} ->
            {ok, Pid};
        {error, _} = Error ->
            Error
    catch
        exit:{noproc, _} ->
            do_start(ParentNode, Attempts - 1);
        exit:{normal, _} ->
            do_start(ParentNode, Attempts - 1)
    end.

%% =====================================================================
%%  TESTING - Test functions for the agent.
%% =====================================================================

-spec ping() -> ok.
ping() ->
    ok.

%% =====================================================================
%% NODE WATCHER - gen_server callbacks and watcher for Nodes.
%% =====================================================================

-spec init(node()) -> {ok, state()} | {stop, term()}.
init(ParentNode) when is_atom(ParentNode) ->
    %% Turns an incoming exit signal into an {'EXIT', _, _} message that handle_info/2 stops on.
    process_flag(trap_exit, true),
    case add_node(#state{nodes = #{}}, ParentNode) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call({register, node()} | term(), {pid(), term()}, state()) ->
                     {reply, {ok, pid()} | {error, term()}, state()}.
handle_call({register, ParentNode}, _From, State) when is_atom(ParentNode) ->
    case add_node(State, ParentNode) of
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
handle_info({nodedown, ParentNode}, #state{nodes = Nodes} = State) ->
    %% Each monitor_node(N, true) is one subscription, so drop ours or it
    %% accumulates across parent churn.
    try
        erlang:monitor_node(ParentNode, false)
    catch
        error:notalive ->
            ok
    end,
    NewNodes = maps:remove(ParentNode, Nodes),
    NewState = State#state{nodes = NewNodes},
    case maps:size(NewNodes) of
        0 ->
            {stop, normal, NewState};
        _ ->
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

%% Subscribe to nodedown for ParentNode.
%% Duplicate registers are a no-op so `erlang:monitor_node/2` does not stack subscriptions.
%% If Node cannot be reached, `erlang:monitor_node(Node, true)` delivers `{nodedown, Node}` to this process.
%% `erlang:monitor_node/2` raises `notalive` only when this VM is not distributed and Node is not 'nonode@nohost'.
-spec add_node(state(), node()) -> {ok, state()} | {error, nodedown}.
add_node(#state{nodes = Nodes} = State, ParentNode)
    when is_atom(ParentNode), is_map(Nodes) ->
    case maps:is_key(ParentNode, Nodes) of
        true ->
            {ok, State};
        false ->
            try erlang:monitor_node(ParentNode, true) of
                _ ->
                    {ok, State#state{nodes = Nodes#{ParentNode => true}}}
            catch
                error:notalive ->
                    {error, nodedown}
            end
    end.

%% `purge` stops all processes running this module and deletes the module old module code.
%% `delete` moves current module code to old code.
%% second `purge` purges the old module code.
-spec purge_code() -> ok.
purge_code() ->
    code:purge(?MODULE),
    code:delete(?MODULE),
    code:purge(?MODULE),
    ok.
