defmodule Anubis.Server.Component.Icons do
  @moduledoc false

  import Peri

  defschema :icons,
            {:list,
             %{
               src: {:required, :string},
               mimeType: :string,
               sizes: {:list, {:either, {{:string, {:eq, "any"}}, {:string, {:regex, ~r/^\d+x\d+$/}}}}}
             }}
end
