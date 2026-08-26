-module(voyager_agent).

-behaviour(gen_server).

%% API
-export([start/1, register/1]).
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
%% Injected onto a remote node. start/1 uses gen_server:start/4 (not
%% start_link) so the process outlives the transient erpc caller.
%%
%% The server monitors each registered ParentNode and exits when the
%% last of them goes down, purging this module from the host.
%% =====================================================================

-spec start(node()) -> {ok, pid()} | {error, term()}.
start(ParentNode) when is_atom(ParentNode) ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, ParentNode, []) of
                {ok, _} = Ok ->
                    Ok;
                {error, {already_started, Pid}} ->
                    ok = register(ParentNode),
                    {ok, Pid};
                Error ->
                    Error
            end;
        Pid ->
            ok = register(ParentNode),
            {ok, Pid}
    end.

%% =====================================================================
%% Register a parent node and listen for nodedown messages.
%% =====================================================================
-spec register(node()) -> ok | {error, term()}.
register(ParentNode) when is_atom(ParentNode) ->
    gen_server:call(?MODULE, {register, ParentNode}).

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

-spec init(node()) -> {ok, state()} | {stop, notalive}.
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
    %% The second code:purge/1 kills processes still running this
    %% module. Spawn so this gen_server can finish stopping first.
    spawn(fun purge_code/0),
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% =====================================================================
%% Internal
%% =====================================================================

%% Subscribe to nodedown for ParentNode. Duplicate registers are a no-op
%% so we do not stack erlang:monitor_node/2 subscriptions.
-spec add_node(state(), node()) -> {ok, state()} | {error, notalive}.
add_node(#state{nodes = Nodes} = State, ParentNode)
    when is_atom(ParentNode), is_map(Nodes) ->
    case maps:is_key(ParentNode, Nodes) of
        true ->
            {error, {already_registered, ParentNode}};
        false ->
            case monitor_node(ParentNode) of
                false ->
                    {error, notalive};
                true ->
                    {ok, State#state{nodes = Nodes#{ParentNode => true}}}
            end
    end;
add_node(State, _ParentNode) ->
    {error, {wrong_state, State}}.

%% erlang:monitor_node/2 also delivers nodedown if the connection cannot
%% be (re)established. It raises notalive when this VM is not distributed.
-spec monitor_node(node()) -> boolean().
monitor_node(ParentNode) ->
    try erlang:monitor_node(ParentNode, true) of
        _ ->
            true
    catch
        error:notalive ->
            false
    end.

-spec purge_code() -> boolean().
purge_code() ->
    code:purge(?MODULE),
    code:delete(?MODULE),
    code:purge(?MODULE).
