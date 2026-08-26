-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([register/1]).
-export([info/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Voyager nodes currently attached. The agent stops and purges
%% its own code when this map becomes empty (last ParentNode is gone).
-record(state, {nodes = #{} :: #{node() => true}}).

-type state() :: #state{nodes :: #{node() => true}}.

%% =====================================================================
%% API - functions exposed to be used by the Voyager via erpc.
%% =====================================================================

%% =====================================================================
%% Adds the parent to the list of nodes and returns the server pid.
%% If the server is not running, it starts it and registers the parent.
%% Uses `gen_server:start/4` so the process outlives the transient erpc caller.
%% =====================================================================

-spec register(node()) -> {ok, pid()} | {error, nodedown} | {error, term()}.
register(ParentNode) when is_atom(ParentNode) ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, ParentNode, []) of
                {ok, Pid} ->
                    {ok, Pid};
                {error, {already_started, Pid}} ->
                    do_register(Pid, ParentNode);
                Error ->
                    Error
            end;
        Pid ->
            do_register(Pid, ParentNode)
    end.

%% =====================================================================
%% Information about the node and its metrics.
%% =====================================================================

-type metric() ::
    {node, node()} |
    {erlang_version, string()} |
    {memory, [{atom(), non_neg_integer()}]} |
    {process_count, non_neg_integer()} |
    {reductions, {non_neg_integer(), non_neg_integer()}}.

-spec info() -> [metric()].
info() ->
    [{node, node()},
     {erlang_version, erlang:system_info(otp_release)},
     {memory, erlang:memory()},
     {process_count, erlang:system_info(process_count)},
     {reductions, erlang:statistics(reductions)}].

%% =====================================================================
%% `gen_server` callbacks implementation.
%% =====================================================================

-spec init(node()) -> {ok, state()} | {stop, term()}.
init(ParentNode) when is_atom(ParentNode) ->
    %% So terminate/2 runs on shutdown and can purge injected code.
    process_flag(trap_exit, true),
    case add_node(#state{nodes = #{}}, ParentNode) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call({register, node()} | term(), {pid(), term()}, state()) ->
                     {reply, ok | {error, term()}, state()}.
handle_call({register, ParentNode}, _From, State) when is_atom(ParentNode) ->
    case add_node(State, ParentNode) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info({nodedown, node()} | term(), state()) ->
                     {noreply, state()} | {stop, normal, state()}.
handle_info({nodedown, ParentNode}, #state{nodes = Nodes} = State) ->
    NewNodes = maps:remove(ParentNode, Nodes),
    NewState = State#state{nodes = NewNodes},
    case maps:size(NewNodes) of
        0 ->
            {stop, normal, NewState};
        _ ->
            {noreply, NewState}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    %% The second `code:purge/1` kills processes still running this module.
    %% Spawn so this gen_server can finish stopping first.
    spawn(fun purge_code/0),
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% =====================================================================
%% Internal
%% =====================================================================

-spec do_register(pid(), node()) -> {ok, pid()} | {error, term()}.
do_register(ServerPid, ParentNode) ->
    case gen_server:call(?MODULE, {register, ParentNode}) of
        ok ->
            {ok, ServerPid};
        {error, _} = Error ->
            Error
    end.

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

-spec purge_code() -> boolean().
purge_code() ->
    code:purge(?MODULE),
    code:delete(?MODULE),
    code:purge(?MODULE).
