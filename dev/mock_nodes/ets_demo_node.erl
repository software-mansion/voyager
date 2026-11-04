%% Seeds a plain Erlang node with ETS tables covering every Erlang data type.
%%
%% Run:
%%   dev/mock_nodes/erl_ets.sh
%%
%% Then in Voyager connect to "erl_ets@127.0.0.1" with cookie "demo".
-module(ets_demo_node).
-export([start/0]).

-record(user, {id, name, email, roles = [], meta = #{}}).
-record(address, {street, city, zip}).
-record(profile, {user, address = #address{}, tags = []}).
-record(state, {socket, buffer = <<>>, timeout = 5000, pending = queue:new()}).
-record(empty, {}).

start() ->
    Self = self(),
    Owner = spawn(fun() ->
        seed(),
        Self ! seeded,
        receive stop -> ok end
    end),
    register(ets_demo_owner, Owner),
    receive seeded -> ok end,
    io:format("node ready: ~s  (cookie: demo)~n", [node()]).

seed() ->
    all_erlang_types = ets:new(all_erlang_types, [ordered_set, named_table, public]),
    ets:insert(all_erlang_types, [
        {atom, ok},
        {atom_quoted, 'hello world'},
        {atom_unicode, 'zażółć'},
        {atom_elixir_module, 'Elixir.Enum'},
        {atom_special, [true, false, undefined]},
        {integer, 42},
        {integer_negative, -7},
        {integer_based, [16#FF, 2#1010, 36#VOYAGER]},
        {integer_char, $a},
        {integer_big, 1 bsl 100},
        {float, 3.14},
        {float_extremes, [-0.0, 1.0e308, 5.0e-324]},
        {string, "hello"},
        {string_unicode, "zażółć 🚀"},
        {string_empty, ""},
        {string_escapes, "quote \" backslash \\ newline \n tab \t"},
        {binary, <<"hello">>},
        {binary_unicode, <<"zażółć 🚀"/utf8>>},
        {binary_empty, <<>>},
        {binary_bytes, <<0, 1, 2, 255>>},
        {binary_latin1, <<255, 254>>},
        {binary_long, binary:copy(<<"lorem ipsum ">>, 1000)},
        {bitstring, <<1:3>>},
        {bitstring_mixed, <<1, 2, 5:3>>},
        {iolist, [<<"GET ">>, "/path", [$?, <<"q=1">>], $\n]},
        {list, [1, two, "three", 4.0]},
        {list_improper, [1, 2 | tail]},
        {list_nested, [[1, [2, [3, [4]]]]]},
        {proplist, [{name, <<"voyager">>}, {port, 4000}, debug, {opts, [{timeout, 5000}]}]},
        {tuple, {ok, <<"value">>}},
        {tuple_empty, {}},
        {tuple_error, {error, {timeout, 5000}}},
        {map, #{name => <<"voyager">>, tags => [a, b]}},
        {map_empty, #{}},
        {map_mixed_keys, #{1 => int, "s" => string, {t, 1} => tuple, [1] => list}},
        {map_large, maps:from_list([{list_to_atom("key_" ++ integer_to_list(N)), N} || N <- lists:seq(1, 40)])},
        {record_user, #user{id = 1, name = <<"Alice">>, email = <<"alice@example.com">>, roles = [admin]}},
        {record_defaults, #user{id = 2}},
        {record_nested, #profile{user = #user{id = 3, name = <<"Bob">>}, address = #address{street = <<"Main 1">>, city = <<"Kraków"/utf8>>, zip = "30-001"}, tags = [vip]}},
        {record_gen_server_state, #state{socket = make_ref()}},
        {record_empty, #empty{}},
        {datetime, calendar:universal_time()},
        {timestamp, os:timestamp()},
        {dict, dict:from_list([{a, 1}, {b, 2}])},
        {orddict, orddict:from_list([{a, 1}, {b, 2}])},
        {sets_v2, sets:from_list([1, 2, 3])},
        {gb_sets, gb_sets:from_list([1, 2, 3])},
        {gb_trees, gb_trees:from_orddict([{a, 1}, {b, 2}])},
        {queue, queue:from_list([1, 2, 3])},
        {array, array:from_list([a, b, c])},
        {pid, self()},
        {port, hd(erlang:ports())},
        {reference, make_ref()},
        {fun_external, fun lists:map/2},
        {fun_anonymous, fun(X) -> X * 2 end},
        {exception, try error(badarg) catch Class:Reason:Stack -> {Class, Reason, Stack} end},
        {term_to_binary, term_to_binary({hello, world})},
        {everything_nested, #{
            list => [1, "str", <<"bin">>, atom, {tuple}],
            record => #user{id = 4},
            pid => self(),
            deep => {a, {b, {c, #{d => [{e, <<"f">>}]}}}}
        }}
    ]),

    users = ets:new(users, [set, named_table, public, {keypos, #user.id}]),
    ets:insert(users, [
        #user{id = N, name = list_to_binary("user_" ++ integer_to_list(N)), roles = [member], meta = #{logins => N * 3}}
     || N <- lists:seq(1, 25)
    ]),

    sessions = ets:new(sessions, [bag, named_table, public]),
    ets:insert(sessions, [{N rem 5, make_ref(), self(), os:timestamp()} || N <- lists:seq(1, 20)]),
    ok.
