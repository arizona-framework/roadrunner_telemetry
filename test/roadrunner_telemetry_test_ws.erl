-module(roadrunner_telemetry_test_ws).
-moduledoc false.

%% Test-only `roadrunner_ws_handler` that echoes text frames back.

-behaviour(roadrunner_ws_handler).

-export([handle_frame/2]).

-spec handle_frame(roadrunner_ws:frame(), term()) -> roadrunner_ws_handler:result().
handle_frame(#{opcode := text, payload := Payload}, State) ->
    {reply, [{text, Payload}], State}.
