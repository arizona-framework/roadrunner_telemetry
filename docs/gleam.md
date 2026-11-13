# Gleam

Use roadrunner_telemetry from a Gleam app that runs on Roadrunner through
[roadrunner_gleam](https://hex.pm/packages/roadrunner_gleam).

## Installation

Add the package:

```sh
gleam add roadrunner_telemetry
```

Roadrunner reads its event handler once, when it starts, and Gleam starts
it before your `main` function runs. A Gleam app has no config file, so
pass the handler to the Erlang VM with `ERL_FLAGS`:

```sh
ERL_FLAGS="-roadrunner event_handler roadrunner_telemetry" gleam run
```

The same works for `gleam test` and for the `entrypoint.sh` of an
`erlang-shipment`.

## Usage

Bind `telemetry:attach/4` with `@external` and decode the metadata you
need:

```gleam
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/io

@external(erlang, "telemetry", "attach")
fn attach(
  id: String,
  event: List(Atom),
  handler: fn(List(Atom), Dynamic, Dynamic, Nil) -> Nil,
  config: Nil,
) -> Dynamic

pub fn log_requests() -> Nil {
  let event = [
    atom.create("roadrunner"),
    atom.create("request"),
    atom.create("stop"),
  ]
  let _ = attach("log-requests", event, log_request, Nil)
  Nil
}

fn log_request(_event, _measurements, metadata: Dynamic, _config) -> Nil {
  let decoder = {
    use path <- decode.field(atom.create("path"), decode.string)
    use status <- decode.field(atom.create("status"), decode.int)
    decode.success(path <> " -> " <> int.to_string(status))
  }
  case decode.run(metadata, decoder) {
    Ok(line) -> io.println(line)
    Error(_) -> Nil
  }
}
```

Call `log_requests()` in `main` before you start the listener. The
example needs `gleam_erlang` in your dependencies for `atom`.

See `m:roadrunner_telemetry` for every event with its measurements and
metadata.
