-module(demo_connection).

-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-elvis([{elvis_style, invalid_dynamic_call, #{ignore => [emqx_connection]}}]).

%% API
-export([
    start_link/3
]).

%% Callback
-export([init/4]).

-record(state, {
    %% TCP/TLS Transport
    transport :: esockd:transport(),
    %% TCP/TLS Socket
    socket :: esockd:socket(),
    %% Peername of the connection
    peername :: emqx_types:peername(),
    %% Sockname of the connection
    sockname :: emqx_types:peername(),
    %% Sock State
    sockstate :: emqx_types:sockstate(),
    %% Listener Type and Name
    listener :: {Type :: atom(), Name :: atom()},

    %% limiter timers
    limiter_timer :: undefined | reference(),

    %% QUIC conn owner pid if in use.
    quic_conn_pid :: pid()
}).


-spec start_link
    (esockd:transport(), esockd:socket(), emqx_channel:opts()) ->
        {ok, pid()};
    (
        demo_quic_stream,
        {ConnOwner :: pid(), quicer:connection_handle(), quicer:new_conn_props()},
        emqx_quic_connection:cb_state()
    ) ->
        {ok, pid()}.

start_link(Transport, Socket, Options) ->
    Args = [self(), Transport, Socket, Options],
    CPid = proc_lib:spawn_link(?MODULE, init, Args),
    {ok, CPid}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

init(Parent, Transport, RawSocket, Options) ->
    case Transport:wait(RawSocket) of
        {ok, Socket} ->
            run_loop(Parent, init_state(Transport, Socket, Options));
        {error, Reason} ->
            ok = Transport:fast_close(RawSocket),
            {error, Reason}
    end.

init_state(
    Transport,
    Socket,
    #{listener := Listener} = Opts
) ->
    {ok, Peername} = Transport:ensure_ok_or_exit(peername, [Socket]),
    {ok, Sockname} = Transport:ensure_ok_or_exit(sockname, [Socket]),
    #state{
        transport = Transport,
        socket = Socket,
        peername = Peername,
        sockname = Sockname,
        sockstate = idle,
        listener = Listener,
        limiter_timer = undefined,
        %% for quic streams to inherit
        quic_conn_pid = maps:get(conn_pid, Opts, undefined)
    }.

run_loop(
    Parent,
    State = #state{
        transport = Transport,
        socket = Socket
    }
) ->
    ?LOG_INFO(#{msg => "start loop"}),
    ok.
