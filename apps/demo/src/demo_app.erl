%%%-------------------------------------------------------------------
%% @doc demo public API
%% @end
%%%-------------------------------------------------------------------

-module(demo_app).

-behaviour(application).

-export([start_quic/0, stop_quic/0]).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, _} = ranch:start_listener(tcp_demo,
        ranch_ssl, #{socket_opts => [{port, 5555}, {certfile, "cert/cert.pem"}, {keyfile, "cert/key.pem"}]},
        echo_protocol, []
    ),
    demo_sup:start_link().

start_quic() ->
    {ok, _} = ranch:start_listener(tcp_quic,
        ranch_quic, #{socket_opts => [{port, 5556}, {certfile, "cert/cert.pem"}, {keyfile, "cert/key.pem"}]},
        echo_protocol, []
    ).

stop_quic() ->
    ranch:stop_listener(tcp_quic).

stop(_State) ->
    ranch:stop_listener(tcp_demo),
    ok.

%% internal functions
