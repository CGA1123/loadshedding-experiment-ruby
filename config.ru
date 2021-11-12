require "puma"
require "libhoney"
require "time"
require "shed"

LOAD_SHED = ENV["LOAD_SHED"] == "1"

class HoneyMiddleware
  def initialize(app)
    @app = app

    at_exit { libhoney.close(true) }
  end

  def call(env)
    start = current
    request_start = env["HTTP_X_REQUEST_START"].to_i
    params = Rack::Utils.parse_nested_query(env[Rack::QUERY_STRING])
    label = params.fetch("label", "unknown")

    response = @app.call(env)

    record(label, request_start, start, current, response[0])

    response
  end

  private

  def record(label, request_start, app_start, app_finish, status)
    event = libhoney.event
    event.add(
      "label" => label,
      "load_shedding_enabled" => LOAD_SHED,
      "response.queue_time" => app_start - request_start,
      "response.serve_time" => app_finish - app_start,
      "response.total_time" => app_finish - request_start,
      "response.status" => status
    )

    event.timestamp = Time.at(request_start / 1000.0)
    event.send
  end

  def libhoney
    @libhoney ||= Libhoney::Client.new(
      writekey: ENV["HONEYCOMB_WRITE_KEY"],
      dataset: "cpuspin-ruby"
    )
  end

  def current
    (Time.now.to_f * 1_000).to_i
  end
end

def spin(ms)
  now = current

  while Shed.time_left? && (current - now) < ms
  end
end

def current
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000).to_i
end

def spin?(percent)
  percent <= (rand(1..100))
end

use HoneyMiddleware
use Shed::RackMiddleware::Propagate, delta: Shed::HerokuDelta if LOAD_SHED

run ->(env) do
  percent = Rack::Utils.parse_nested_query(env[Rack::QUERY_STRING]).fetch("percent", "0").to_i

  spin_ms = 100
  spin_ms = 1_000 if !percent.zero? && spin?(percent)

  spin(spin_ms)

  [200, {}, []]
end
