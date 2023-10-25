-module(demo_quic_connection).

-include_lib("quicer/include/quicer.hrl").
-include_lib("kernel/include/logger.hrl").

-behaviour(quicer_connection).

-export([
    init/1,
    new_conn/3,
    connected/3,
    transport_shutdown/3,
    shutdown/3,
    closed/3,
    local_address_changed/3,
    peer_address_changed/3,
    streams_available/3,
    peer_needs_streams/3,
    resumed/3,
    new_stream/3
]).

-export([activate_data_streams/2]).

-export([
    handle_call/3,
    handle_info/2
]).

-type cb_state() :: #{
    %% connecion owner pid
    conn_pid := pid(),
    %% Pid of ctrl stream
    ctrl_pid := undefined | pid(),
    %% quic connecion handle
    conn := undefined | quicer:conneciton_handle(),
    %% Data streams that handoff from this process
    %% these streams could die/close without effecting the connecion/session.
    %@TODO type?
    streams := [{pid(), quicer:stream_handle()}],
    %% New stream opts
    stream_opts := map(),
    %% If conneciton is resumed from session ticket
    is_resumed => boolean(),
    %% mqtt message serializer config
    serialize => undefined,
    _ => _
}.
-type cb_ret() :: quicer_lib:cb_ret().

-spec activate_data_streams(pid(), {
    emqx_frame:parse_state(), emqx_frame:serialize_opts(), emqx_channel:channel()
}) -> ok.
activate_data_streams(ConnOwner, {PS, Serialize, Channel}) ->
    gen_server:call(ConnOwner, {activate_data_streams, {PS, Serialize, Channel}}, infinity).

%% @doc conneciton owner init callback
-spec init(map()) -> {ok, cb_state()}.
init(#{stream_opts := SOpts} = S) when is_list(SOpts) ->
    init(S#{stream_opts := maps:from_list(SOpts)});
init(ConnOpts) when is_map(ConnOpts) ->
    {ok, init_cb_state(ConnOpts)}.

-spec closed(quicer:conneciton_handle(), quicer:conn_closed_props(), cb_state()) ->
    {stop, normal, cb_state()}.
closed(_Conn, #{is_peer_acked := _} = Prop, S) ->
    {stop, normal, S}.

%% @doc handle the new incoming connecion as the connecion acceptor.
-spec new_conn(quicer:connection_handle(), quicer:new_conn_props(), cb_state()) ->
    {ok, cb_state()} | {error, any(), cb_state()}.
new_conn(
    Conn,
    #{version := _Vsn} = ConnInfo,
    #{conn := undefined, ctrl_pid := undefined} = S
) ->
    process_flag(trap_exit, true),
    %% Start control stream process
    StartOption = S,
    {ok, CtrlPid} = demo_connection:start_link(
        demo_quic_stream,
        {self(), Conn, maps:without([crypto_buffer], ConnInfo)},
        StartOption
    ),
    receive
        {CtrlPid, stream_acceptor_ready} ->
            ok = quicer:async_handshake(Conn),
            {ok, S#{conn := Conn, ctrl_pid := CtrlPid}};
        {'EXIT', _Pid, _Reason} ->
            {stop, stream_accept_error, S}
    end.

%% @doc callback when connection is connected.
-spec connected(quicer:connection_handle(), quicer:connected_props(), cb_state()) ->
    {ok, cb_state()} | {error, any(), cb_state()}.
connected(_Conn, Props, S) ->
    ?LOG_DEBUG(Props),
    {ok, S}.

%% @doc callback when connection is resumed from 0-RTT
-spec resumed(quicer:connection_handle(), SessionData :: binary() | false, cb_state()) -> cb_ret().
%% reserve resume conn with callback.
%% resumed(Conn, Data, #{resumed_callback := ResumeFun} = S) when
%%     is_function(ResumeFun)
%% ->
%%     ResumeFun(Conn, Data, S);
resumed(_Conn, _Data, S) ->
    {ok, S#{is_resumed := true}}.

%% @doc callback for handling orphan data streams
%%      depends on the connecion state and control stream state.
-spec new_stream(quicer:stream_handle(), quicer:new_stream_props(), cb_state()) -> cb_ret().
new_stream(
    Stream,
    #{is_orphan := true, flags := _Flags} = Props,
    #{
        conn := Conn,
        streams := Streams,
        stream_opts := SOpts,
        zone := Zone,
        limiter := Limiter,
        parse_state := PS,
        channel := Channel,
        serialize := Serialize
    } = S
) ->
    %% Cherry pick options for data streams
    SOpts1 = SOpts#{
        is_local => false,
        zone => Zone,
        limiter => Limiter,
        parse_state => PS,
        channel => Channel,
        serialize => Serialize,
        quic_event_mask => ?QUICER_STREAM_EVENT_MASK_START_COMPLETE
    },
    {ok, NewStreamOwner} = quicer_stream:start_link(
        emqx_quic_data_stream,
        Stream,
        Conn,
        SOpts1,
        Props
    ),
    case quicer:handoff_stream(Stream, NewStreamOwner, {PS, Serialize, Channel}) of
        ok ->
            ok;
        E ->
            %% Only log, keep connecion alive.
            ?LOG_ERROR(#{message => "new stream handoff failed", stream => Stream, error => E})
    end,
    %% @TODO maybe keep them in `inactive_streams'
    {ok, S#{streams := [{NewStreamOwner, Stream} | Streams]}}.

%% @doc callback for handling remote connecion shutdown.
-spec shutdown(quicer:connection_handle(), quicer:error_code(), cb_state()) -> cb_ret().
shutdown(Conn, ErrorCode, S) ->
    ErrorCode =/= 0 andalso ?LOG_DEBUG(#{error_code => ErrorCode, state => S}),
    _ = quicer:async_shutdown_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0),
    {ok, S}.

%% @doc callback for handling transport error, such as idle timeout
-spec transport_shutdown(quicer:connection_handle(), quicer:transport_shutdown_props(), cb_state()) ->
    cb_ret().
transport_shutdown(_C, DownInfo, S) when is_map(DownInfo) ->
    ?LOG_DEBUG(DownInfo),
    {ok, S}.

%% @doc callback for handling for peer addr changed.
-spec peer_address_changed(quicer:connection_handle(), quicer:quicer_addr(), cb_state) -> cb_ret().
peer_address_changed(_C, _NewAddr, S) ->
    %% @TODO update conn info in emqx_quic_stream
    {ok, S}.

%% @doc callback for handling local addr change, currently unused
-spec local_address_changed(quicer:connection_handle(), quicer:quicer_addr(), cb_state()) ->
    cb_ret().
local_address_changed(_C, _NewAddr, S) ->
    {ok, S}.

%% @doc callback for handling remote stream limit updates
-spec streams_available(
    quicer:connection_handle(),
    {BidirStreams :: non_neg_integer(), UnidirStreams :: non_neg_integer()},
    cb_state()
) -> cb_ret().
streams_available(_C, {BidirCnt, UnidirCnt}, S) ->
    {ok, S#{
        peer_bidi_stream_count => BidirCnt,
        peer_unidi_stream_count => UnidirCnt
    }}.

%% @doc callback for handling request when remote wants for more streams
%%      should cope with rate limiting
%% @TODO this is not going to get triggered in current version
%% ref: https://github.com/microsoft/msquic/issues/3120
-spec peer_needs_streams(quicer:connection_handle(), undefined, cb_state()) -> cb_ret().
peer_needs_streams(_C, undefined, S) ->
    ?LOG_INFO(#{
        msg => "ignore: peer need more streames", info => maps:with([conn_pid, ctrl_pid], S)
    }),
    {ok, S}.

%% @doc handle API calls
-spec handle_call(Req :: term(), gen_server:from(), cb_state()) -> cb_ret().
handle_call(
    {activate_data_streams, {PS, Serialize, Channel} = ActivateData},
    _From,
    #{streams := Streams} = S
) ->
    _ = [
        catch demo_quic_data_stream:activate_data(OwnerPid, ActivateData)
     || {OwnerPid, _Stream} <- Streams
    ],
    {reply, ok, S#{
        channel := Channel,
        serialize := Serialize,
        parse_state := PS
    }};
handle_call(_Req, _From, S) ->
    {reply, {error, unimpl}, S}.

%% @doc handle DOWN messages from streams.
handle_info({'EXIT', Pid, Reason}, #{ctrl_pid := Pid, conn := Conn} = S) ->
    _ = quicer:async_shutdown_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, Reason),
    {ok, S};
handle_info({'EXIT', Pid, Reason}, #{streams := Streams} = S) ->
    case proplists:is_defined(Pid, Streams) of
        true when
            Reason =:= normal orelse
                Reason =:= {shutdown, protocol_error} orelse
                Reason =:= killed
        ->
            {ok, S};
        true ->
            ?LOG_INFO(#{message => "Data stream unexpected exit", reason => Reason}),
            {ok, S};
        false ->
            {stop, unknown_pid_down, S}
    end.

-spec init_cb_state(map()) -> cb_state().
init_cb_state(#{} = Map) ->
    Map#{
        conn_pid => self(),
        ctrl_pid => undefined,
        conn => undefined,
        streams => [],
        parse_state => undefined,
        channel => undefined,
        serialize => undefined,
        is_resumed => false
    }.
