%%%-------------------------------------------------------------------
%% @doc demo public API
%% @end
%%%-------------------------------------------------------------------

-module(demo_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    logger:set_primary_config(level, debug),
    start_quic(),
    demo_sup:start_link().

start_quic() ->
    ListenOpts = [{certfile, "cert/cert.pem"}, 
        {keyfile, "cert/key.pem"},
        {alpn, ["demo"]},
        {conn_acceptors, 10},
        {peer_bidi_stream_count, 1}],
    ConnectionOpts = #{
        conn_callback => demo_server_connection,
        peer_unidi_stream_count => 1,
        peer_bidi_stream_count => 10,
        listener => {quic, demo},
        limiter => 10
    },
    StreamOpts = #{
        stream_callback => demo_server_stream,
        active => 1
    },
    quicer:spawn_listener(demo, 5556, {ListenOpts, ConnectionOpts, StreamOpts}).

stop(_State) ->
    quicer:terminate_listener(demo),
    ok.

%% internal functions
