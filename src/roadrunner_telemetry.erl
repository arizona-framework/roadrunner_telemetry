-module(roadrunner_telemetry).
-moduledoc """
A [roadrunner](https://github.com/arizona-framework/roadrunner) event
handler that emits every roadrunner event as a
[`telemetry`](https://hex.pm/packages/telemetry) event.

Roadrunner hands its request, connection, and WebSocket events to one
`roadrunner_event_handler` and drops them by default. Make this module
the handler to get them as `telemetry` events, and from there into
`telemetry_metrics`, Prometheus, OpenTelemetry, or your own handlers:

```erlang
%% sys.config
[{roadrunner, [{event_handler, roadrunner_telemetry}]}].
```

Then attach handlers as usual:

```erlang
telemetry:attach(log_requests, [roadrunner, request, stop],
    fun(_Event, #{duration := D}, #{method := M, path := P, status := S}, _) ->
        Us = erlang:convert_time_unit(D, native, microsecond),
        logger:info("~s ~s -> ~p (~p us)", [M, P, S, Us])
    end, undefined).
```

## Events

Durations are in `native` time units: convert them with
`erlang:convert_time_unit/3`. Each event's meaning is described in
`roadrunner_event_handler`.

The request events follow the `telemetry` span convention: start
carries `system_time` and `monotonic_time`, stop and exception carry
`duration` and `monotonic_time`, and all three share a
`telemetry_span_context` in their metadata, so tools that pair span
events (such as `opentelemetry_telemetry`) can pair them.

- `[roadrunner, request, start]`
  - Measurements: `system_time`, `monotonic_time`
  - Metadata: `request_id`, `peer`, `method`, `path`, `scheme`,
    `listener_name`, `telemetry_span_context`, plus `client_ip` when the
    listener resolved one behind a trusted proxy
- `[roadrunner, request, stop]`
  - Measurements: `duration`, `monotonic_time`
  - Metadata: the start metadata plus `status` and `response_kind`
- `[roadrunner, request, exception]`
  - Measurements: `duration`, `monotonic_time`
  - Metadata: the start metadata plus `kind` and `reason`
- `[roadrunner, request, rejected]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `peer`, `reason`
- `[roadrunner, request, throttled]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `reason`
- `[roadrunner, response, send_failed]`
  - Measurements: `system_time`
  - Metadata: `phase`, `reason`, plus the connection's `logger` process
    metadata when it was set (`request_id`, `peer`, `method`, `path`)
- `[roadrunner, listener, accept]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `peer`
- `[roadrunner, listener, conn_close]`
  - Measurements: `duration`
  - Metadata: `listener_name`, `peer`, `requests_served`, `reason`
- `[roadrunner, listener, conn_rejected]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `reason`
- `[roadrunner, listener, accept_error]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `reason`
- `[roadrunner, listener, slots_reconciled]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `released`, `counter_was`,
    `live_conns_bounded`
- `[roadrunner, drain, acknowledged]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `peer`, `request_id`, `deadline`
- `[roadrunner, ws, upgrade]`
  - Measurements: `system_time`
  - Metadata: `listener_name`, `peer`, `request_id`, `module`
- `[roadrunner, ws, frame_in]` and `[roadrunner, ws, frame_out]`
  - Measurements: `system_time`, `payload_size`
  - Metadata: the upgrade metadata plus `opcode`
- `[roadrunner, ws, frame_rejected]`
  - Measurements: `system_time`, `size`
  - Metadata: the upgrade metadata plus `reason`

An event roadrunner adds before this package knows it is dropped.

## Stability

An event's name, and the measurement and metadata keys listed above,
follow the stability of the roadrunner event they come from (see
`roadrunner_event_handler`): `[roadrunner, request, start | stop]`,
`[roadrunner, ws, upgrade]`, and `[roadrunner, ws, frame_out]` are
stable. Any event may gain keys in a minor release.

## Cost

Every event goes through `telemetry:execute/3`, which looks its
handlers up in an ETS table shared by every scheduler. Once your
handlers are attached, call `telemetry:persist/0` to move that table
into `persistent_term`, which makes the lookup much cheaper under load.
""".

-behaviour(roadrunner_event_handler).

-export([handle_event/2]).

-doc "Emit `Event` as a `telemetry` event. See the module documentation.".
-spec handle_event(atom(), term()) -> term().
handle_event(request_start, Req) ->
    StartMono = erlang:monotonic_time(),
    Metadata = (request_metadata(Req))#{telemetry_span_context => make_ref()},
    ok = telemetry:execute(
        [roadrunner, request, start],
        #{system_time => erlang:system_time(), monotonic_time => StartMono},
        Metadata
    ),
    {StartMono, Metadata};
handle_event(request_stop, {{StartMono, Metadata}, Status, Kind}) ->
    StopMono = erlang:monotonic_time(),
    telemetry:execute(
        [roadrunner, request, stop],
        #{duration => StopMono - StartMono, monotonic_time => StopMono},
        Metadata#{status => Status, response_kind => Kind}
    );
handle_event(request_exception, {{StartMono, Metadata}, Class, Reason}) ->
    StopMono = erlang:monotonic_time(),
    telemetry:execute(
        [roadrunner, request, exception],
        #{duration => StopMono - StartMono, monotonic_time => StopMono},
        Metadata#{kind => Class, reason => Reason}
    );
handle_event(request_rejected, {ListenerName, Peer, Reason}) ->
    now_event([roadrunner, request, rejected], #{
        listener_name => ListenerName, peer => Peer, reason => Reason
    });
handle_event(request_throttled, {ListenerName, Reason}) ->
    now_event([roadrunner, request, throttled], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(response_send_failed, {Phase, Reason}) ->
    now_event(
        [roadrunner, response, send_failed],
        with_logger_metadata(#{phase => Phase, reason => Reason})
    );
handle_event(listener_accept, {ListenerName, Peer}) ->
    StartMono = erlang:monotonic_time(),
    ok = now_event([roadrunner, listener, accept], #{
        listener_name => ListenerName, peer => Peer
    }),
    {StartMono, ListenerName, Peer};
handle_event(
    listener_conn_close, {{StartMono, ListenerName, Peer}, RequestsServed, Reason}
) ->
    telemetry:execute(
        [roadrunner, listener, conn_close],
        #{duration => erlang:monotonic_time() - StartMono},
        #{
            listener_name => ListenerName,
            peer => Peer,
            requests_served => RequestsServed,
            reason => Reason
        }
    );
handle_event(listener_conn_rejected, {ListenerName, Reason}) ->
    now_event([roadrunner, listener, conn_rejected], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(listener_accept_error, {ListenerName, Reason}) ->
    now_event([roadrunner, listener, accept_error], #{
        listener_name => ListenerName, reason => Reason
    });
handle_event(slots_reconciled, {ListenerName, Released, CounterWas, LiveConnsBounded}) ->
    now_event([roadrunner, listener, slots_reconciled], #{
        listener_name => ListenerName,
        released => Released,
        counter_was => CounterWas,
        live_conns_bounded => LiveConnsBounded
    });
handle_event(drain_acknowledged, {Req, Deadline}) ->
    now_event([roadrunner, drain, acknowledged], #{
        listener_name => maps:get(listener_name, Req, undefined),
        peer => maps:get(peer, Req, undefined),
        request_id => maps:get(request_id, Req, undefined),
        deadline => Deadline
    });
handle_event(ws_upgrade, {ListenerName, Peer, RequestId, Module}) ->
    Metadata = #{
        listener_name => ListenerName, peer => Peer, request_id => RequestId, module => Module
    },
    ok = now_event([roadrunner, ws, upgrade], Metadata),
    Metadata;
handle_event(ws_frame_in, {Metadata, Opcode, PayloadSize}) ->
    telemetry:execute(
        [roadrunner, ws, frame_in],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata#{opcode => Opcode}
    );
handle_event(ws_frame_out, {Metadata, Opcode, PayloadSize}) ->
    telemetry:execute(
        [roadrunner, ws, frame_out],
        #{system_time => erlang:system_time(), payload_size => PayloadSize},
        Metadata#{opcode => Opcode}
    );
handle_event(ws_frame_rejected, {Metadata, Reason, Size}) ->
    telemetry:execute(
        [roadrunner, ws, frame_rejected],
        #{system_time => erlang:system_time(), size => Size},
        Metadata#{reason => Reason}
    );
handle_event(_Event, _Args) ->
    ok.

-spec now_event(telemetry:event_name(), map()) -> ok.
now_event(Event, Metadata) ->
    telemetry:execute(Event, #{system_time => erlang:system_time()}, Metadata).

%% The request fields every request event carries. `client_ip` is only
%% present when the listener resolved one behind a trusted proxy.
-spec request_metadata(map()) -> map().
request_metadata(
    #{
        request_id := RequestId,
        peer := Peer,
        method := Method,
        target := Target,
        scheme := Scheme,
        listener_name := ListenerName
    } = Req
) ->
    Metadata = #{
        request_id => RequestId,
        peer => Peer,
        method => Method,
        path => Target,
        scheme => Scheme,
        listener_name => ListenerName
    },
    case Req of
        #{client_ip := ClientIP} -> Metadata#{client_ip => ClientIP};
        #{} -> Metadata
    end.

%% The connection's `logger` process metadata (`request_id`, `peer`,
%% `method`, `path`) merged under `Extra`, when it was set.
-spec with_logger_metadata(map()) -> map().
with_logger_metadata(Extra) ->
    case logger:get_process_metadata() of
        undefined -> Extra;
        Md -> maps:merge(Md, Extra)
    end.
