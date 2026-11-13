# Elixir

Use roadrunner_telemetry from an Elixir app that runs on Roadrunner through
[roadrunner_plug](https://hex.pm/packages/roadrunner_plug), with Plug or
Phoenix.

## Installation

Add it to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:roadrunner_plug, ">= 0.0.0"},
    {:roadrunner_telemetry, ">= 0.0.0"}
  ]
end
```

Make it Roadrunner's event handler in `config/config.exs`:

```elixir
config :roadrunner, event_handler: :roadrunner_telemetry
```

Roadrunner reads the handler once, when it starts. Mix applies your config
before that, so this is all it takes.

## Usage

Attach `:telemetry` handlers as usual:

```elixir
defmodule MyApp.RequestLogger do
  require Logger

  def attach do
    :telemetry.attach(
      "log-requests",
      [:roadrunner, :request, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, %{duration: duration}, metadata, _config) do
    %{method: method, path: path, status: status} = metadata
    us = System.convert_time_unit(duration, :native, :microsecond)
    Logger.info("#{method} #{path} -> #{status} (#{us} us)")
  end
end
```

Call `MyApp.RequestLogger.attach()` when your application starts. Pass a
function capture such as `&__MODULE__.handle_event/4`, not an anonymous
function: `:telemetry` runs it faster and does not warn.

The events work with `Telemetry.Metrics` too, so you can add them to a
Phoenix app's metrics and see them in LiveDashboard:

```elixir
summary("roadrunner.request.stop.duration",
  tags: [:method, :status],
  unit: {:native, :millisecond}
)
```

See `m:roadrunner_telemetry` for every event with its measurements and
metadata.
