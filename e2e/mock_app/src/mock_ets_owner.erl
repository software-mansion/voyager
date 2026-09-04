%% Owns a handful of ETS tables with known names and shapes, so the ETS e2e
%% tests have deterministic rows next to the system tables of the node.
-module(mock_ets_owner).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(mock_ets_cache, [named_table, public, set, {read_concurrency, true}]),
    ets:insert(mock_ets_cache, [{N, N * N} || N <- lists:seq(1, 100)]),

    ets:new(mock_ets_events, [named_table, protected, duplicate_bag]),
    ets:insert(mock_ets_events, [{event, N} || N <- lists:seq(1, 10)]),

    ets:new(mock_ets_secrets, [named_table, private, ordered_set]),
    ets:insert(mock_ets_secrets, {key, value}),

    Unnamed = ets:new(mock_ets_unnamed, [private, set]),
    {ok, #{unnamed => Unnamed}}.

handle_call(_Msg, _From, State) -> {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
