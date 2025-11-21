defmodule Anubis.Server.Component.Resource do
  @moduledoc """
  Defines the behaviour for MCP resources.

  Resources represent data that can be read by the client, such as files,
  documents, or any other content. Each resource is identified by a URI
  and can provide content in various formats.

  ## Example

      defmodule MyServer.Resources.Documentation do
        @behaviour Anubis.Server.Behaviour.Resource

        alias Anubis.Server.Frame

        @impl true
        def uri, do: "file:///docs/readme.md"

        @impl true
        def name, do: "Project README"

        @impl true
        def description, do: "The main documentation for this project"

        @impl true
        def mime_type, do: "text/markdown"

        @impl true
        def read(_params, frame) do
          case File.read("README.md") do
            {:ok, content} ->
              # Can track access in frame
              new_frame = Frame.assign(frame, :last_resource_access, DateTime.utc_now())
              {:ok, content, new_frame}

            {:error, reason} ->
              {:error, "Failed to read README: \#{inspect(reason)}"}
          end
        end
      end

  ## Example with dynamic content

      defmodule MyServer.Resources.SystemStatus do
        @behaviour Anubis.Server.Behaviour.Resource

        @impl true
        def uri, do: "system://status"

        @impl true
        def name, do: "System Status"

        @impl true
        def description, do: "Current system status and metrics"

        @impl true
        def mime_type, do: "application/json"

        @impl true
        def read(_params, frame) do
          status = %{
            uptime: System.uptime(),
            memory: :erlang.memory(),
            user_id: frame.assigns[:user_id],
            timestamp: DateTime.utc_now()
          }

          {:ok, Jason.encode!(status), frame}
        end
      end
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  @type params :: map()
  @type content :: binary() | String.t()

  @type t :: %__MODULE__{
          uri: String.t() | nil,
          uri_template: String.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          mime_type: String.t(),
          handler: module | nil,
          title: String.t() | nil
        }

  defstruct [
    :uri,
    :uri_template,
    :name,
    description: nil,
    mime_type: "text/plain",
    handler: nil,
    title: nil
  ]

  @doc """
  Returns the URI that identifies this resource.

  The URI should be unique within the server and follow standard URI conventions.
  Common schemes include:
  - `file://` for file-based resources
  - `http://` or `https://` for web resources
  - Custom schemes for application-specific resources

  Note: Either `uri/0` or `uri_template/0` must be implemented, but not both.
  """
  @callback uri() :: String.t()

  @doc """
  Returns the URI template that identifies this resource template.

  URI templates follow RFC 6570 syntax and allow parameterized resource URIs.
  For example: `file:///{path}` or `db:///{table}/{id}`

  Note: Either `uri/0` or `uri_template/0` must be implemented, but not both.
  """
  @callback uri_template() :: String.t()

  @doc """
  Returns the `name` that identifies this resource.

  Intended for programmatic or logical use, but used as a
  display name in past specs or fallback (if title isn't present).
  """
  @callback name() :: String.t()

  @doc """
  Returns the title that identifies this resource.

  Intended for UI and end-user contexts — optimized to be human-readable and easily understood,
  even by those unfamiliar with domain-specific terminology.

  If not provided, the name should be used for display.
  """
  @callback title() :: String.t()

  @doc """
  Returns the MIME type of the resource content.

  Common MIME types:
  - `text/plain` for plain text
  - `text/markdown` for Markdown
  - `application/json` for JSON data
  - `text/html` for HTML
  - `application/octet-stream` for binary data
  """
  @callback mime_type() :: String.t()

  @doc """
  Returns the description of this resource.

  The description helps AI assistants understand what data the resource provides.
  If not provided, the module's `@moduledoc` will be used automatically.

  ## Examples

      def description do
        "Application configuration settings"
      end

      # With dynamic content
      def description do
        {uptime_ms, _} = :erlang.statistics(:wall_clock)
        "System metrics (uptime: \#{div(uptime_ms, 1000)}s)"
      end
  """
  @callback description() :: String.t()

  @doc """
  Reads the resource content.

  ## Parameters

  - `params` - Optional parameters from the client (typically empty for resources)
  - `frame` - The server frame containing context and state

  ## Return Values

  - `{:ok, content}` - Resource read successfully, frame unchanged
  - `{:ok, content, new_frame}` - Resource read successfully with frame updates
  - `{:error, reason}` - Failed to read resource

  ## Content Types

  The content should match the declared MIME type:
  - For text types, return a String
  - For binary types, return binary data
  - For JSON, return the JSON-encoded string
  """
  @callback read(params :: params(), frame :: Frame.t()) ::
              {:reply, response :: Response.t(), new_state :: Frame.t()}
              | {:noreply, new_state :: Frame.t()}
              | {:error, error :: Error.t(), new_state :: Frame.t()}

  @optional_callbacks title: 0, uri: 0, uri_template: 0, description: 0

  defimpl JSON.Encoder, for: __MODULE__ do
    alias Anubis.Server.Component.Resource

    def encode(%Resource{uri_template: uri_template} = resource, _) when not is_nil(uri_template) do
      %{
        uriTemplate: uri_template,
        name: resource.name
      }
      |> then(&if resource.title, do: Map.put(&1, :title, resource.title), else: &1)
      |> then(&if resource.description, do: Map.put(&1, :description, resource.description), else: &1)
      |> then(&if resource.mime_type, do: Map.put(&1, :mimeType, resource.mime_type), else: &1)
      |> JSON.encode!()
    end

    def encode(%Resource{} = resource, _) do
      resource
      |> Map.take([:name, :uri, :description, :title])
      |> Map.put(:mimeType, resource.mime_type)
      |> JSON.encode!()
    end
  end
end
