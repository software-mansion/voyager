%% Entry points invoked from Playwright tests via erl_call, e.g.:
%%   erl_call -name test@127.0.0.1 -c e2e_cookie -a 'mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]'
%% Every function returns the atom ok; erl_call prints it and the tests assert on it.
-module(mock_app_ctl).

-export([add_child/2, remove_child/2, reset/0]).

-define(BASELINE, #{mock_dyn_sup_a => [], mock_dyn_sup_b => [mock_dyn_worker_b1]}).

add_child(Sup, Name) ->
    {ok, _} =
        supervisor:start_child(Sup,
                               #{id => Name,
                                 start => {mock_worker, start_link, [Name]},
                                 restart => transient}),
    ok.

remove_child(Sup, Name) ->
    ok = supervisor:terminate_child(Sup, Name),
    ok = supervisor:delete_child(Sup, Name),
    ok.

%% Terminate every dynamic child not present in the baseline tree.
reset() ->
    maps:foreach(fun(Sup, Keep) ->
                    [remove_child(Sup, Id)
                     || {Id, _, _, _} <- supervisor:which_children(Sup),
                        not lists:member(Id, Keep)]
                 end,
                 ?BASELINE),
    ok.
