-module(dual_tcp_dist).
-moduledoc false.

%% The only -proto_dist carrier: net_kernel tries several carriers in reverse order, so IPv4-first is decided in setup/5.
%% As the IPv4 driver it accepts IPv6 literal hosts, so app@<IPv6> reached over the v4 SSH tunnel passes gen_setup's host check.

-export([select/1, setup/5, close/1, address/0, is_node_name/1]).
-export([setopts/2, getopts/2]).
-export([family/0, parse_address/1, connect/3, send/2, send/3, recv/3]).

select(Node) -> inet_tcp_dist:fam_select(inet, Node) orelse inet_tcp_dist:fam_select(inet6, Node).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Driver =
        case inet_tcp_dist:fam_select(inet, Node) of
            true -> ?MODULE;
            false -> inet6_tcp
        end,
    inet_tcp_dist:gen_setup(Driver, Node, Type, MyNode, LongOrShortNames, SetupTime).

address() -> inet_tcp_dist:gen_address(?MODULE).
close(Socket) -> inet_tcp:close(Socket).
is_node_name(Node) -> inet_tcp_dist:is_node_name(Node).
setopts(S, Opts) -> inet_tcp_dist:setopts(S, Opts).
getopts(S, Opts) -> inet_tcp_dist:getopts(S, Opts).

family() -> inet.
parse_address(Host) -> inet:parse_strict_address(Host).
connect(Ip, Port, Opts) -> inet_tcp:connect(Ip, Port, Opts).
send(Socket, Packet) -> inet_tcp:send(Socket, Packet).
send(Socket, Packet, Opts) -> inet_tcp:send(Socket, Packet, Opts).
recv(Socket, Length, Timeout) -> inet_tcp:recv(Socket, Length, Timeout).
