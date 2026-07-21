%% Supervisor whose children the tests add/remove at runtime via mock_app_ctl.
%% Plain one_for_one (not simple_one_for_one) so which_children reports real
%% child-spec ids that become node labels in the supervision tree.
-module(mock_dyn_sup).
-behaviour(supervisor).

-export([start_link/2, init/1]).

start_link(Name, ChildSpecs) ->
    supervisor:start_link({local, Name}, ?MODULE, ChildSpecs).

init(ChildSpecs) ->
    {ok, {#{strategy => one_for_one}, ChildSpecs}}.
