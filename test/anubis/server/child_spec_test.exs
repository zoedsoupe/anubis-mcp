defmodule Anubis.Server.ChildSpecTest do
  use ExUnit.Case, async: false

  @auth_config [
    authorization_servers: ["https://auth.example.com"],
    resource: "https://api.example.com"
  ]

  defmodule NoAuthorizationServer do
    @moduledoc false

    use Anubis.Server,
      name: "no-auth-child-spec-server",
      version: "1.0.0",
      capabilities: []
  end

  defmodule AuthorizationServer do
    @moduledoc false

    @auth_config [
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com"
    ]
    use Anubis.Server,
      name: "auth-child-spec-server",
      version: "1.0.0",
      capabilities: [],
      authorization: @auth_config
  end

  test "compiling a server without authorization emits no warnings" do
    module = Module.concat(__MODULE__, "NoAuthCompileProbe#{System.unique_integer([:positive])}")

    {_compiled, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Anubis.Server,
            name: "issue-173-no-auth",
            version: "1.0.0",
            capabilities: []
        end
        """)
      end)

    assert diagnostics == []
  end

  test "generated child_spec/1 for a server without authorization has no authorization merge" do
    module = Module.concat(__MODULE__, "NoAuthStructProbe#{System.unique_integer([:positive])}")

    child_spec = compile_child_spec_abstract_code(module)

    refute contains_keyword_put_call?(child_spec)
  end

  test "child_spec/1 omits authorization when the server has no authorization config" do
    %{start: {Anubis.Server.Supervisor, :start_link, [NoAuthorizationServer, opts]}} =
      NoAuthorizationServer.child_spec(transport: :stdio)

    assert opts == [transport: :stdio]
    refute Keyword.has_key?(opts, :authorization)
  end

  test "child_spec/1 merges the configured authorization when the caller omits it" do
    %{start: {Anubis.Server.Supervisor, :start_link, [AuthorizationServer, opts]}} =
      AuthorizationServer.child_spec(transport: :streamable_http)

    assert opts[:transport] == :streamable_http
    assert opts[:authorization] == @auth_config
  end

  test "child_spec/1 keeps caller-provided authorization" do
    caller_auth = [
      authorization_servers: ["https://override.example.com"],
      resource: "https://override.example.com"
    ]

    %{start: {Anubis.Server.Supervisor, :start_link, [AuthorizationServer, opts]}} =
      AuthorizationServer.child_spec(authorization: caller_auth)

    assert opts[:authorization] == caller_auth
  end

  defp compile_child_spec_abstract_code(module) do
    source = """
    defmodule #{inspect(module)} do
      use Anubis.Server,
        name: "issue-173-no-auth",
        version: "1.0.0",
        capabilities: []
    end
    """

    child_spec_abstract_code(source)
  end

  defp child_spec_abstract_code(source) do
    compiler_options = Code.compiler_options()

    forms =
      try do
        Code.compiler_options(debug_info: true)
        [{_module, beam}] = Code.compile_string(source)
        {:ok, {_module, [abstract_code: {:raw_abstract_v1, forms}]}} = :beam_lib.chunks(beam, [:abstract_code])
        forms
      after
        Code.compiler_options(compiler_options)
      end

    Enum.find(forms, &match?({:function, _, :child_spec, 1, _}, &1))
  end

  defp contains_keyword_put_call?(term) do
    term_contains?(term, fn
      {:call, _, {:remote, _, {:atom, _, Keyword}, {:atom, _, :put}}, _} -> true
      _ -> false
    end)
  end

  defp term_contains?(term, predicate) do
    cond do
      predicate.(term) -> true
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.any?(&term_contains?(&1, predicate))
      is_list(term) -> Enum.any?(term, &term_contains?(&1, predicate))
      true -> false
    end
  end
end
