%% Statically nested supervisor; instances form the mock_deep_sup_1..3 chain.
-module(mock_deep_sup).
-behaviour(supervisor).

-export([start_link/2, init/1]).

start_link(Name, ChildSpecs) ->
    supervisor:start_link({local, Name}, ?MODULE, ChildSpecs).

init(ChildSpecs) ->
    {ok, {#{strategy => one_for_one}, ChildSpecs}}.
