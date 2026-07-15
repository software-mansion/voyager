%% Trivial registered gen_server; the tests locate tree nodes by these names.
-module(mock_worker).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

init([]) -> {ok, #{}}.

handle_call(_Msg, _From, State) -> {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
