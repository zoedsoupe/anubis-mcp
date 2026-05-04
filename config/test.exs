import Config

# Suppress logs that escape ExUnit's per-test capture (e.g. supervisor
# `terminate/2` callbacks running after the test process finishes). Tests that
# need to assert on log content should still use `capture_log/1`, which
# overrides this floor for its scope.
config :logger, level: :warning
