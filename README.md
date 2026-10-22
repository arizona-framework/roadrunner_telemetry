# roadrunner_telemetry

[`telemetry`](https://hex.pm/packages/telemetry) events for
[Roadrunner](https://github.com/arizona-framework/roadrunner).

Roadrunner hands its request, connection, and WebSocket events to one event
handler, and drops them by default. `roadrunner_telemetry` is that handler: it
turns every event into a `telemetry` event, so `telemetry_metrics`, Prometheus
reporters, OpenTelemetry, LiveDashboard, and your own handlers can use them.

## Installation

roadrunner_telemetry works with Roadrunner 0.11 or later. It doesn't pull
Roadrunner in itself, so it never pins your Roadrunner version: add it next to
`roadrunner` in your `rebar.config`:

```erlang
{deps, [
    roadrunner,
    roadrunner_telemetry
]}.
```

Make it Roadrunner's event handler in your `sys.config`:

```erlang
[{roadrunner, [{event_handler, roadrunner_telemetry}]}].
```

## Usage

Attach `telemetry` handlers as usual:

```erlang
telemetry:attach(log_requests, [roadrunner, request, stop],
    fun(_Event, #{duration := D}, #{method := M, path := P, status := S}, _) ->
        Us = erlang:convert_time_unit(D, native, microsecond),
        logger:info("~s ~s -> ~p (~p us)", [M, P, S, Us])
    end, undefined).
```

Request events follow the `telemetry` span convention, with a shared
`telemetry_span_context`, so tools that pair start and stop events work out of
the box. Once your handlers are attached, `telemetry:persist/0` makes the event
lookup cheaper under load.

See the [module documentation](https://hexdocs.pm/roadrunner_telemetry) for every
event with its measurements and metadata.

## 🚧 Status

roadrunner_telemetry is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version
in your deps if you need stability across upgrades.

## Sponsors

roadrunner_telemetry is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## Contributing

Contributions are welcome! Run `rebar3 precommit` before opening a pull request:
it checks formatting, runs xref, hank, dialyzer, and the docs build, and runs the
tests with a 100% coverage gate.

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

roadrunner_telemetry is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/roadrunner_telemetry).

See [LICENSE.md](https://github.com/arizona-framework/roadrunner_telemetry/blob/main/LICENSE.md) for more information.
