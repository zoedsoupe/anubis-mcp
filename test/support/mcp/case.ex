defmodule Anubis.MCP.Case do
  @moduledoc """
  Test case template for MCP protocol testing.

  Provides a consistent setup and common imports for MCP tests.
  """

  use ExUnit.CaseTemplate

  using opts do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)

      import Anubis.MCP.Assertions
      import Anubis.MCP.Builders
      import Anubis.MCP.Setup

      require Anubis.MCP.Message

      @moduletag capture_log: true
    end
  end
end
