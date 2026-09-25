-module(dual_tcp_dist).
-moduledoc false.

%% Dual-stack -proto_dist carrier: setup/5 picks the IPv4 or IPv6 driver per
%% target from how the epmd module resolves it. Voyager starts distribution
%% with dist_listen: false, so there is no listen/accept side here.

-export([select/1, setup/5, close/1, address/0, is_node_name/1]).
-export([setopts/2, getopts/2]).
-export([choose_driver/1]).

%% The only -proto_dist module, so select/1 must claim nodes of either family.
select(Node) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} ->
            resolves(Name, Host, inet) orelse resolves(Name, Host, inet6);
        _ ->
            false
    end.

address() ->
    inet_tcp_dist:gen_address(inet_tcp).

close(Socket) ->
    inet_tcp:close(Socket).

%% gen_setup/6 spawns and returns a pid immediately, so the family cannot be
%% retried after a failed connect -- it must be decided up front, here.
setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Driver = choose_driver(Node),
    inet_tcp_dist:gen_setup(
        Driver, Node, Type, MyNode, LongOrShortNames, SetupTime
    ).

%% Prefer IPv4 when a host resolves both ways; SSH-tunnelled nodes always
%% resolve to the v4 tunnel listener. dual_tcp instead of inet_tcp so a
%% tunnelled node named app@<IPv6-literal> passes gen_setup's literal-host
%% check; see dual_tcp:parse_address/1.
choose_driver(Node) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} ->
            case resolves(Name, Host, inet) of
                true ->
                    dual_tcp;
                false ->
                    case resolves(Name, Host, inet6) of
                        true -> inet6_tcp;
                        false -> dual_tcp
                    end
            end;
        _ ->
            dual_tcp
    end.

resolves(Name, Host, Family) ->
    EpmdMod = net_kernel:epmd_module(),
    case EpmdMod:address_please(Name, Host, Family) of
        {ok, _Addr} -> true;
        {ok, _Addr, _Port, _Creation} -> true;
        _ -> false
    end.

is_node_name(Node) when is_atom(Node) ->
    inet_tcp_dist:is_node_name(Node).

setopts(S, Opts) -> inet_tcp_dist:setopts(S, Opts).
getopts(S, Opts) -> inet_tcp_dist:getopts(S, Opts).
