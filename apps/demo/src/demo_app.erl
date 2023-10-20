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
    ListenOpts = [{certfile, "cert/cert.pem"}, 
        {keyfile, "cert/key.pem"},
        {alpn, ["demo"]},
        {conn_acceptors, 10},
        {peer_bidi_stream_count, 1}],
    ConnectionOpts = #{
        conn_callback => emqx_quic_connection,
        peer_unidi_stream_count => 1,
        peer_bidi_stream_count => 10,
        listener => {quic, demo},
        limiter => 10
    },
    StreamOpts = #{
        stream_callback => demo_quic_stream,
        active => 1
    },
    quicer:spawn_listener(demo, 5556, {ListenOpts, ConnectionOpts, StreamOpts}).

stop_quic() ->
    quicer:terminate_listener(demo).

stop(_State) ->
    ranch:stop_listener(tcp_demo),
    ok.

%% internal functions
