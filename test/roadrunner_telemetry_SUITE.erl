-module(roadrunner_telemetry_SUITE).
-moduledoc false.

%% End to end through a real roadrunner listener for the events a client
%% can trigger, and straight through `handle_event/2` for the ones only a
%% loaded or misbehaving server produces.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    request_start_and_stop_share_a_span/1,
    request_exception_on_handler_crash/1,
    request_rejected_on_malformed_request/1,
    accept_and_conn_close_with_reason/1,
    websocket_upgrade_and_frames/1,
    client_ip_in_request_metadata/1,
    events_without_a_client/1,
    send_failed_with_and_without_logger_metadata/1,
    unknown_event_is_dropped/1
]).

-define(LISTENER, roadrunner_telemetry_test_listener).

all() ->
    [
        request_start_and_stop_share_a_span,
        request_exception_on_handler_crash,
        request_rejected_on_malformed_request,
        accept_and_conn_close_with_reason,
        websocket_upgrade_and_frames,
        client_ip_in_request_metadata,
        events_without_a_client,
        send_failed_with_and_without_logger_metadata,
        unknown_event_is_dropped
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(roadrunner_telemetry),
    {ok, _} = application:ensure_all_started(roadrunner),
    {ok, _} = roadrunner:start_listener(?LISTENER, #{
        port => 0, routes => roadrunner_telemetry_test_handler
    }),
    [{port, roadrunner_listener:port(?LISTENER)} | Config].

end_per_suite(_Config) ->
    ok = roadrunner:stop_listener(?LISTENER).

init_per_testcase(_TestCase, Config) ->
    Ref = make_ref(),
    ok = telemetry:attach_many(
        Ref, all_events(), fun forward/4, self()
    ),
    [{handler, Ref} | Config].

end_per_testcase(_TestCase, Config) ->
    ok = telemetry:detach(?config(handler, Config)).

%% --- tests ---

request_start_and_stop_share_a_span(Config) ->
    ok = http_get(?config(port, Config), ~"/"),
    {StartM, StartMd} = event([roadrunner, request, start]),
    {StopM, StopMd} = event([roadrunner, request, stop]),
    #{system_time := _, monotonic_time := StartMono} = StartM,
    #{duration := Duration, monotonic_time := StopMono} = StopM,
    ?assertEqual(StopMono - StartMono, Duration),
    #{
        telemetry_span_context := SpanCtx,
        request_id := RequestId,
        method := ~"GET",
        path := ~"/",
        scheme := http,
        listener_name := ?LISTENER,
        peer := {{127, 0, 0, 1}, _}
    } = StartMd,
    ?assert(is_reference(SpanCtx)),
    ?assertMatch(
        #{
            telemetry_span_context := SpanCtx,
            request_id := RequestId,
            status := 200,
            response_kind := buffered
        },
        StopMd
    ).

request_exception_on_handler_crash(Config) ->
    ok = http_get(?config(port, Config), ~"/crash"),
    {_, #{telemetry_span_context := SpanCtx}} = event([roadrunner, request, start]),
    {ExcM, ExcMd} = event([roadrunner, request, exception]),
    ?assertMatch(#{duration := _, monotonic_time := _}, ExcM),
    ?assertMatch(
        #{
            telemetry_span_context := SpanCtx,
            path := ~"/crash",
            kind := error,
            reason := boom,
            stacktrace := [_ | _]
        },
        ExcMd
    ).

request_rejected_on_malformed_request(Config) ->
    ok = send_raw(?config(port, Config), ~"NOT-A-REQUEST\r\n\r\n"),
    {M, Md} = event([roadrunner, request, rejected]),
    ?assertMatch(#{system_time := _}, M),
    ?assertMatch(
        #{listener_name := ?LISTENER, peer := {{127, 0, 0, 1}, _}, reason := bad_request_line},
        Md
    ),
    {_, CloseMd} = event([roadrunner, listener, conn_close]),
    ?assertMatch(#{requests_served := 0, reason := rejected}, CloseMd).

accept_and_conn_close_with_reason(Config) ->
    ok = http_get(?config(port, Config), ~"/"),
    {AcceptM, AcceptMd} = event([roadrunner, listener, accept]),
    ?assertMatch(#{system_time := _}, AcceptM),
    ?assertMatch(#{listener_name := ?LISTENER, peer := {{127, 0, 0, 1}, _}}, AcceptMd),
    {CloseM, CloseMd} = event([roadrunner, listener, conn_close]),
    ?assertMatch(#{duration := _}, CloseM),
    %% The request asked for `Connection: close`.
    ?assertMatch(
        #{
            listener_name := ?LISTENER,
            peer := {{127, 0, 0, 1}, _},
            requests_served := 1,
            reason := normal
        },
        CloseMd
    ).

websocket_upgrade_and_frames(Config) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, ?config(port, Config), [binary, {active, false}], 1000
    ),
    ok = gen_tcp:send(Sock, [
        ~"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        ~"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]),
    {ok, <<"HTTP/1.1 101 ", _/binary>>} = gen_tcp:recv(Sock, 0, 1000),
    ok = gen_tcp:send(Sock, masked_text(~"hi")),
    {ok, <<16#81, 2, "hi">>} = gen_tcp:recv(Sock, 4, 1000),
    ok = gen_tcp:close(Sock),
    {_, UpgradeMd} = event([roadrunner, ws, upgrade]),
    #{
        listener_name := ?LISTENER,
        peer := {{127, 0, 0, 1}, _},
        request_id := RequestId,
        module := roadrunner_telemetry_test_ws
    } = UpgradeMd,
    ?assert(is_binary(RequestId)),
    {InM, InMd} = event([roadrunner, ws, frame_in]),
    ?assertMatch(#{system_time := _, payload_size := 2}, InM),
    ?assertEqual(UpgradeMd#{opcode => text}, InMd),
    {OutM, OutMd} = event([roadrunner, ws, frame_out]),
    ?assertMatch(#{system_time := _, payload_size := 2}, OutM),
    ?assertEqual(UpgradeMd#{opcode => text}, OutMd).

client_ip_in_request_metadata(_Config) ->
    Req = #{
        request_id => ~"0123456789abcdef",
        peer => {{10, 0, 0, 1}, 4000},
        method => ~"GET",
        target => ~"/",
        scheme => https,
        listener_name => probe,
        client_ip => {203, 0, 113, 7}
    },
    _Span = roadrunner_telemetry:handle_event(request_start, Req),
    {_, Md} = event([roadrunner, request, start]),
    ?assertMatch(#{client_ip := {203, 0, 113, 7}, scheme := https}, Md).

events_without_a_client(_Config) ->
    ok = roadrunner_telemetry:handle_event(request_throttled, {probe, rate_limit}),
    ?assertMatch(
        {#{system_time := _}, #{listener_name := probe, reason := rate_limit}},
        event([roadrunner, request, throttled])
    ),
    ok = roadrunner_telemetry:handle_event(listener_conn_rejected, {probe, max_clients}),
    ?assertMatch(
        {#{system_time := _}, #{listener_name := probe, reason := max_clients}},
        event([roadrunner, listener, conn_rejected])
    ),
    ok = roadrunner_telemetry:handle_event(listener_accept_error, {probe, emfile}),
    ?assertMatch(
        {#{system_time := _}, #{listener_name := probe, reason := emfile}},
        event([roadrunner, listener, accept_error])
    ),
    ok = roadrunner_telemetry:handle_event(slots_reconciled, {probe, 2, 5, 3}),
    ?assertMatch(
        {#{system_time := _}, #{
            listener_name := probe, released := 2, counter_was := 5, live_conns_bounded := 3
        }},
        event([roadrunner, listener, slots_reconciled])
    ),
    Req = #{listener_name => probe, peer => undefined, request_id => ~"id"},
    ok = roadrunner_telemetry:handle_event(drain_acknowledged, {Req, 1000}),
    ?assertMatch(
        {#{system_time := _}, #{
            listener_name := probe, peer := undefined, request_id := ~"id", deadline := 1000
        }},
        event([roadrunner, drain, acknowledged])
    ),
    %% A request missing the optional keys still yields every metadata key.
    ok = roadrunner_telemetry:handle_event(drain_acknowledged, {#{}, undefined}),
    ?assertMatch(
        {_, #{listener_name := undefined, request_id := undefined, deadline := undefined}},
        event([roadrunner, drain, acknowledged])
    ),
    WsSpan = #{listener_name => probe, module => some_ws},
    ok = roadrunner_telemetry:handle_event(ws_frame_rejected, {WsSpan, max_frame_size, 70000}),
    ?assertMatch(
        {#{system_time := _, size := 70000}, #{module := some_ws, reason := max_frame_size}},
        event([roadrunner, ws, frame_rejected])
    ).

send_failed_with_and_without_logger_metadata(_Config) ->
    ok = roadrunner_telemetry:handle_event(response_send_failed, {buffered_response, closed}),
    {M, Md} = event([roadrunner, response, send_failed]),
    ?assertMatch(#{system_time := _}, M),
    ?assertEqual(#{phase => buffered_response, reason => closed}, Md),
    ok = logger:set_process_metadata(#{request_id => ~"id", method => ~"GET"}),
    try
        ok = roadrunner_telemetry:handle_event(response_send_failed, {sendfile_body, timeout}),
        ?assertMatch(
            {_, #{request_id := ~"id", method := ~"GET", phase := sendfile_body, reason := timeout}},
            event([roadrunner, response, send_failed])
        )
    after
        logger:unset_process_metadata()
    end.

unknown_event_is_dropped(_Config) ->
    ?assertEqual(ok, roadrunner_telemetry:handle_event(an_event_added_later, {})),
    receive
        {telemetry_event, Event, _, _} -> ct:fail({unexpected_event, Event})
    after 0 -> ok
    end.

%% --- helpers ---

all_events() ->
    [
        [roadrunner, request, start],
        [roadrunner, request, stop],
        [roadrunner, request, exception],
        [roadrunner, request, rejected],
        [roadrunner, request, throttled],
        [roadrunner, response, send_failed],
        [roadrunner, listener, accept],
        [roadrunner, listener, conn_close],
        [roadrunner, listener, conn_rejected],
        [roadrunner, listener, accept_error],
        [roadrunner, listener, slots_reconciled],
        [roadrunner, drain, acknowledged],
        [roadrunner, ws, upgrade],
        [roadrunner, ws, frame_in],
        [roadrunner, ws, frame_out],
        [roadrunner, ws, frame_rejected]
    ].

forward(Event, Measurements, Metadata, Pid) ->
    Pid ! {telemetry_event, Event, Measurements, Metadata}.

%% The next event named `Event`; other events stay queued. Each listener
%% process delivers its own events in order.
event(Event) ->
    receive
        {telemetry_event, Event, Measurements, Metadata} -> {Measurements, Metadata}
    after 2000 -> ct:fail({no_event, Event})
    end.

http_get(Port, Path) ->
    send_raw(Port, [~"GET ", Path, ~" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"]).

%% Send `Bytes` and read until the server closes the connection.
send_raw(Port, Bytes) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Sock, Bytes),
    ok = drain(Sock),
    gen_tcp:close(Sock).

drain(Sock) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, _} -> drain(Sock);
        {error, closed} -> ok
    end.

%% A client text frame (FIN, masked) carrying `Payload`, under 126 bytes.
masked_text(Payload) ->
    Mask = <<1, 2, 3, 4>>,
    <<16#81, (16#80 bor byte_size(Payload)), Mask/binary, (mask(Payload, Mask))/binary>>.

mask(Payload, <<M1, M2, M3, M4>>) ->
    Key = binary:copy(<<M1, M2, M3, M4>>, byte_size(Payload) div 4 + 1),
    crypto:exor(Payload, binary:part(Key, 0, byte_size(Payload))).
