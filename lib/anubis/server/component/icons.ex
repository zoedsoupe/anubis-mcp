defmodule Anubis.Server.Component.Icons do
  @moduledoc false

  import Peri

  # `src` is a URI in the MCP icon contract, so it must carry a scheme
  # (`https:`, `data:`, `file:`). Bare paths are not publishable.
  @uri ~r/^[a-zA-Z][a-zA-Z\d+.-]*:/

  defschema :icons,
            {:list,
             %{
               src: {:required, {:string, {:regex, @uri}}},
               mimeType: :string,
               sizes: {:list, {:either, {{:string, {:eq, "any"}}, {:string, {:regex, ~r/^\d+x\d+$/}}}}},
               theme: {:enum, ~w(light dark)}
             }}
end
