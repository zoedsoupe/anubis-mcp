Application.ensure_all_started(:mimic)

Mox.defmock(Anubis.MockTransport, for: Anubis.Transport.Behaviour)

if Code.ensure_loaded?(:gun), do: Mimic.copy(:gun)

ExUnit.start()
