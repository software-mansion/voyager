%% Trivial registered gen_server; the tests locate tree nodes by these names.
%%
%% Also exposes relation helpers used by the supervision-tree e2e tests to wire
%% up monitor relationships between two otherwise-unrelated branches of
%% the tree, plus a teardown (clear_relations) so a test's relations never leak
%% into the next one.
-module(mock_worker).
-behaviour(gen_server).

-export([start_link/1, monitor_process/2, clear_relations/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

monitor_process(Name, RegName) -> gen_server:call(Name, {monitor, RegName}).
clear_relations(Name) -> gen_server:call(Name, clear_relations).

init([]) -> {ok, #{monitors => []}}.

handle_call({monitor, RegName}, _From, State) when is_atom(RegName) ->
    #{monitors := Monitors} = State,
    case whereis(RegName) of
        Pid when is_pid(Pid) ->
            Ref = erlang:monitor(process, Pid),
            {reply, ok, State#{monitors := [Ref | Monitors]}};
        _ ->
            {reply, {error, "No registered process"}, State}
    end;

handle_call(clear_relations, _From, State) ->
    #{monitors := Monitors} = State,
    [erlang:demonitor(Ref, [flush]) || Ref <- Monitors],
    {reply, ok, State#{monitors := []}};

handle_call(_Msg, _From, State) -> {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
