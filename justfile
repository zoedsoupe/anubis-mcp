setup-venv:
    @echo "Run: source examples/echo/.venv/bin/activate"

echo-server transport="stdio":
    source examples/echo/.venv/bin/activate && \
    mcp run -t {{transport}} examples/echo/index.py

calculator-server transport="stdio":
    cd examples/calculator && go build && ./calculator -t {{transport}} || cd -

[working-directory: 'examples/upcase']
upcase-server:
    ANUBIS_MCP_SERVER=true iex -S mix

[working-directory: 'examples/ascii']
ascii-server:
    iex -S mix phx.server

[working-directory: 'examples/echo-elixir']
echo-ex-server transport="sse":
    MCP_TRANSPORT={{transport}} {{ if transport == "sse" { "iex -S mix phx.server" } else { "mix run --no-halt" } }}

update-deps-examples:
    for p in examples/upcase examples/ascii examples/echo-elixir; do \
        (cd "$p" && mix deps.update --all && mix compile --force --warnings-as-errors) || exit 1; \
    done

compile-examples:
    for p in examples/upcase examples/ascii examples/echo-elixir; do \
        (cd "$p" && mix compile --force --warnings-as-errors) || exit 1; \
    done
