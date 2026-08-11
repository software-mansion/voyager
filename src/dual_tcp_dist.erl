-module(dual_tcp_dist).
-moduledoc false.

%% Dual-stack -proto_dist carrier for Voyager.
%%
%% Voyager's own node is hidden and named on loopback (voyager@127.0.0.1), so
%% it never accepts an inbound distribution connection -- it only ever dials
%% out. Therefore this carrier LISTENS IPv4-only (delegating to inet_tcp_dist)
%% and puts all the dual-stack logic in setup/5, which picks the IPv4 or IPv6
%% low-level driver per target from how that target's address resolves.
%%
%% Everything delegates to inet_tcp_dist's family-generic gen_*/fam_* helpers;
%% nothing here reimplements OTP internals, and no dist headers are needed.

-export([
    listen/2,
    accept/1,
    accept_connection/5,
    setup/5,
    close/1,
    select/1,
    address/0,
    is_node_name/1
]).
-export([setopts/2, getopts/2]).

-export([choose_driver/1, family_of/1]).

listen(Name, Host) ->
    inet_tcp_dist:gen_listen(inet_tcp, Name, Host).

accept(Listen) ->
    inet_tcp_dist:gen_accept(inet_tcp, Listen).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    inet_tcp_dist:gen_accept_connection(
        inet_tcp, AcceptPid, Socket, MyNode, Allowed, SetupTime
    ).

address() ->
    inet_tcp_dist:gen_address(inet_tcp).

close(Socket) ->
    inet_tcp:close(Socket).

%% We are the only -proto_dist module, so select/1 must claim every node we
%% can reach under *either* family -- otherwise net_kernel rejects a literal
%% IPv6 target before setup/5 ever runs.
select(Node) ->
    inet_tcp_dist:gen_select(inet_tcp, Node) orelse
        inet_tcp_dist:gen_select(inet6_tcp, Node).

%% gen_setup/6 spawns and returns a pid immediately, so the family cannot be
%% retried after a failed connect -- it must be decided up front, here.
setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Driver = choose_driver(Node),
    inet_tcp_dist:gen_setup(
        Driver, Node, Type, MyNode, LongOrShortNames, SetupTime
    ).

%% The epmd module's resolved address is ground truth: SSH-tunnelled nodes
%% always resolve to a v4 loopback address, direct IPv6 nodes to a v6 address.
%% Prefer IPv4 when a host answers both ways.
choose_driver(Node) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} ->
            case resolved_family(Name, Host, inet) of
                inet ->
                    inet_tcp;
                _ ->
                    case resolved_family(Name, Host, inet6) of
                        inet6 -> inet6_tcp;
                        %% Unreachable both ways: hand to inet_tcp so gen_setup
                        %% fails with the normal distribution error.
                        _ -> inet_tcp
                    end
            end;
        _ ->
            inet_tcp
    end.

resolved_family(Name, Host, Family) ->
    EpmdMod = net_kernel:epmd_module(),
    case EpmdMod:address_please(Name, Host, Family) of
        {ok, Addr} -> family_of(Addr);
        {ok, Addr, _Port, _Cr} -> family_of(Addr);
        _ -> undefined
    end.

family_of(Addr) when tuple_size(Addr) =:= 4 -> inet;
family_of(Addr) when tuple_size(Addr) =:= 8 -> inet6;
family_of(_) -> undefined.

is_node_name(Node) when is_atom(Node) ->
    inet_tcp_dist:is_node_name(Node).

setopts(S, Opts) -> inet_tcp_dist:setopts(S, Opts).
getopts(S, Opts) -> inet_tcp_dist:getopts(S, Opts).
