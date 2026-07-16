Application.ensure_all_started(:mimic)

# The library no longer starts a Finch pool; consumers (and these tests) own it.
{:ok, _} = Finch.start_link(name: Anubis.Finch, pools: %{default: [size: 15]})

Mox.defmock(Anubis.MockTransport, for: Anubis.Transport.Behaviour)

if Code.ensure_loaded?(:gun), do: Mimic.copy(:gun)

ExUnit.start(exclude: [:integration], max_cases: System.schedulers_online() * 2)
