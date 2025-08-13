defmodule TestTools.NestedFieldTool do
  @moduledoc "Tool with nested field definitions"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :name, {:required, :string}, description: "Full name"

    embeds_one :address, description: "Mailing address" do
      field :street, {:required, :string}
      field :city, {:required, :string}
      field :state, :string
      field :zip, :string, format: "postal-code"
    end

    embeds_one :contact do
      field :email, :string, format: "email", description: "Contact email"
      field :phone, :string, format: "phone"
    end
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.text(Response.tool(), "it doesnt matter"), frame}
  end
end

defmodule TestTools.SingleNestedFieldTool do
  @moduledoc "Tool with single nested field"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    embeds_one :user, description: "User information" do
      field :id, {:required, :string}, format: "uuid"
    end
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.text(Response.tool(), "doesnt matter"), frame}
  end
end

defmodule TestTools.DeeplyNestedTool do
  @moduledoc "Tool with deeply nested fields"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    embeds_one :organization do
      field :name, {:required, :string}

      embeds_one :admin, description: "Organization admin" do
        field :name, {:required, :string}

        embeds_one :permissions do
          field :read, {:required, :boolean}
          field :write, {:required, :boolean}
          field :delete, :boolean
        end
      end
    end
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.text(Response.tool(), "doesnt matter"), frame}
  end
end

defmodule TestTools.LegacyTool do
  @moduledoc "Tool using traditional Peri schema syntax without field macros"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    %{
      name: {:required, :string},
      age: {:integer, {:default, 25}},
      email: :string,
      tags: {:list, :string},
      metadata: %{
        created_at: :string,
        updated_at: :string
      }
    }
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.text(Response.tool(), "doesnt matter"), frame}
  end
end

defmodule TestTools.EnumWithTypeTool do
  @moduledoc "Tool demonstrating enum with type specification"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :weight, {:required, :integer}
    field :unit, {:required, {:enum, ["kg", "lb"]}}, type: :string
    field :status, {:enum, ["active", "inactive", "pending"]}, type: :string
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.text(Response.tool(), "executed"), frame}
  end
end

defmodule TestPrompts.FieldPrompt do
  @moduledoc "Test prompt with field metadata"

  use Anubis.Server.Component, type: :prompt

  alias Anubis.Server.Response

  schema do
    field :code, {:required, :string}, description: "The code to review"
    field :language, {:required, :string}, description: "Programming language"
    field :focus_areas, :string, description: "Areas to focus on (optional)"
  end

  @impl true
  def get_messages(_params, frame) do
    {:reply, Response.user_message(Response.prompt(), "hello"), frame}
  end
end

defmodule TestPrompts.NestedPrompt do
  @moduledoc "Prompt with nested fields"

  use Anubis.Server.Component, type: :prompt

  alias Anubis.Server.Response

  schema do
    embeds_one :config, description: "Configuration options" do
      field :model, {:required, :string}, description: "Model to use"
      field :temperature, :float, description: "Temperature setting"
    end
  end

  @impl true
  def get_messages(_params, frame) do
    {:reply, Response.user_message(Response.prompt(), "hello"), frame}
  end
end

defmodule TestPrompts.LegacyPrompt do
  @moduledoc "Legacy prompt without field macros"

  use Anubis.Server.Component, type: :prompt

  alias Anubis.Server.Response

  schema do
    %{
      query: {:required, :string},
      max_results: {:integer, {:default, 10}}
    }
  end

  @impl true
  def get_messages(_params, frame) do
    {:reply, Response.user_message(Response.prompt(), "hello"), frame}
  end
end

defmodule ToolWithAnnotations do
  @moduledoc "A tool with annotations"

  use Anubis.Server.Component,
    type: :tool,
    annotations: %{
      "confidence" => 0.95,
      "category" => "text-processing",
      "tags" => ["nlp", "text", "analysis"]
    }

  alias Anubis.Server.Response

  schema do
    field(:text, {:required, :string}, description: "Text to process")
  end

  @impl true
  def execute(%{text: text}, frame) do
    {:reply, Response.text(Response.tool(), "Processed: #{text}"), frame}
  end
end

defmodule ToolWithoutAnnotations do
  @moduledoc "A tool without annotations"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:input, {:required, :string}, description: "Input value")
  end

  @impl true
  def execute(%{input: input}, frame) do
    {:reply, Response.text(Response.tool(), "Result: #{input}"), frame}
  end
end

defmodule ToolWithCustomAnnotations do
  @moduledoc "A tool with custom annotations implementation"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:data, {:required, :string}, description: "Data to process")
  end

  @impl true
  def execute(%{data: data}, frame) do
    {:reply, Response.text(Response.tool(), "Custom: #{data}"), frame}
  end

  @impl true
  def annotations do
    %{
      "version" => "2.0",
      "experimental" => true,
      "capabilities" => %{
        "streaming" => false,
        "batch" => true
      }
    }
  end
end

defmodule ToolWithOutputSchema do
  @moduledoc "A tool with output schema"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:query, {:required, :string}, description: "Query to process")
    field(:limit, :integer, description: "Result limit")
  end

  output_schema do
    field(
      :results,
      {:required,
       {:list,
        %{
          id: {:required, :string},
          score: {:required, :float},
          title: {:required, :string}
        }}},
      description: "Search results"
    )

    field(:total_count, {:required, :integer}, description: "Total number of results")
    field(:query_time_ms, {:required, :float}, description: "Query execution time")
  end

  @impl true
  def execute(%{query: query}, frame) do
    results = %{
      results: [
        %{id: "1", score: 0.95, title: "Result for #{query}"},
        %{id: "2", score: 0.87, title: "Another result"}
      ],
      total_count: 2,
      query_time_ms: 12.5
    }

    {:reply, Response.structured(Response.tool(), results), frame}
  end
end

defmodule ToolWithInvalidOutput do
  @moduledoc "A tool that returns data not matching its output schema"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:input, {:required, :string})
  end

  output_schema do
    field(:status, {:required, :string})
    field(:count, {:required, :integer})
  end

  @impl true
  def execute(%{input: _}, frame) do
    # Intentionally return wrong type for count
    invalid_data = %{
      status: "ok",
      # Wrong type!
      count: "not a number"
    }

    {:reply, Response.structured(Response.tool(), invalid_data), frame}
  end
end

defmodule ToolWithoutRequiredParams do
  @moduledoc "A tool with no required parameters"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:optional_message, :string, description: "Optional message")
  end

  @impl true
  def execute(params, frame) do
    message = Map.get(params, :optional_message, "default message")
    {:reply, Response.text(Response.tool(), "Tool executed: #{message}"), frame}
  end
end
