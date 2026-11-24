%% Entry points invoked from Playwright tests via erl_call, e.g.:
%%   erl_call -name test@127.0.0.1 -c e2e_cookie -a 'mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]'
%% Every function but trace_session/1, which returns the session id, returns the atom ok;
%% erl_call prints it and the tests assert on it.
-module(mock_app_ctl).

-export([add_child/2, remove_child/2, reset/0, trace_session/1, trace_close/0]).

-define(BASELINE, #{mock_dyn_sup_a => [], mock_dyn_sup_b => [mock_dyn_worker_b1]}).
-define(TRACER, 'Elixir.Voyager.Services.Tracer').

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

%% Starts a session in the connected Voyager tracing mock_tracee:lookup/1, which a loop keeps calling.
%% Prints the session id, which the session page's URL needs.
trace_session(Save) ->
    ok = trace_close(),
    {module, _} = code:ensure_loaded(mock_tracee),
    Voyager = voyager_node(),
    {ok, #{id := Id}} = rpc:call(Voyager, ?TRACER, create, [ui, [{save, Save}]]),
    Config =
        #{module => <<"mock_tracee">>,
          function => <<"lookup">>,
          arity => 1,
          processes => all,
          capture => args,
          return_trace => true,
          max_events => 10000,
          max_time_ms => 300000},
    {ok, _} = rpc:call(Voyager, ?TRACER, configure, [node(), Config, ui]),
    {ok, _} = rpc:call(Voyager, ?TRACER, start, [ui]),
    true = register(mock_tracee_traffic, spawn(mock_tracee, loop, [1])),
    Id.

%% Stops and closes the active session; the stop lands asynchronously, so close is retried.
trace_close() ->
    ok = stop_traffic(),
    Voyager = voyager_node(),
    ok = rpc:call(Voyager, ?TRACER, stop, [ui]),
    close(Voyager, 50).

%% Waits for the exit, as the name stays registered until then and trace_session/1 reuses it.
stop_traffic() ->
    case whereis(mock_tracee_traffic) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.

close(_Voyager, 0) -> {error, busy};
close(Voyager, Tries) ->
    case rpc:call(Voyager, ?TRACER, close, []) of
        ok -> ok;
        {error, busy} -> timer:sleep(100), close(Voyager, Tries - 1)
    end.

voyager_node() ->
    [Voyager | _] =
        [N || N <- nodes(connected), {file, _} <- [rpc:call(N, code, is_loaded, [?TRACER])]],
    Voyager.
