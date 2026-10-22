-module(roadrunner_telemetry_test_handler).
-moduledoc false.

%% Test-only `roadrunner_handler`: `/` answers 200, `/crash` raises, and
%% `/ws` upgrades to the echo WebSocket handler.

-behaviour(roadrunner_handler).

-export([handle/1]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    case roadrunner_req:path(Req) of
        ~"/crash" -> error(boom);
        ~"/ws" -> {{websocket, roadrunner_telemetry_test_ws, undefined}, Req};
        _ -> {roadrunner_resp:text(200, ~"ok"), Req}
    end.
