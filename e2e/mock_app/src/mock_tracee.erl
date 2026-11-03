%% A function the tracing e2e tests trace, called in a loop by mock_app_ctl:start_traffic/0.
-module(mock_tracee).

-export([lookup/1, loop/1]).

lookup(Id) when Id rem 7 =:= 0 -> error({not_found, Id});
lookup(Id) -> {ok, #{id => Id, email => <<"user", (integer_to_binary(Id))/binary, "@shop.test">>}}.

loop(Id) ->
    try ?MODULE:lookup(Id) catch error:_ -> ok end,
    timer:sleep(100),
    loop(Id + 1).
