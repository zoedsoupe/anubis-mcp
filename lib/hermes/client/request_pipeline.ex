defmodule Hermes.Client.RequestPipeline do
  @moduledoc """
  Manages the request lifecycle for MCP client operations.
  
  This module is responsible for:
  - Request creation and ID generation
  - Request timeout management
  - Response correlation
  - Batch request handling
  - Progress token management
  
  ## Architecture
  
  The RequestPipeline manages requests through their complete lifecycle:
  1. **Creation** - Generate unique IDs and track request metadata
  2. **Dispatch** - Send encoded requests via transport
  3. **Tracking** - Monitor timeouts and correlate responses
  4. **Completion** - Handle responses and cleanup resources
  
  ## Features
  
  - Automatic timeout handling with configurable durations
  - Batch request support (protocol version 2025-03-26+)
  - Progress tracking for long-running operations
  - Request cancellation support
  """

  import Peri
  
  alias Hermes.Client.{Request, Operation}
  alias Hermes.MCP.{Message, Error, ID}
  alias Hermes.Protocol
  
  require Logger

  @type request_id :: String.t()
  @type batch_id :: String.t()
  @type from :: GenServer.from()
  
  @type pipeline_state :: %{
    pending_requests: %{request_id() => Request.t()},
    request_timeouts: %{request_id() => reference()},
    batch_requests: %{batch_id() => [request_id()]},
    transport: map()
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates initial pipeline state.
  """
  @spec new(map()) :: pipeline_state()
  def new(opts \\ %{}) do
    %{
      pending_requests: %{},
      request_timeouts: %{},
      batch_requests: %{},
      transport: opts[:transport] || %{}
    }
  end

  @doc """
  Processes a single operation through the request pipeline.
  
  Returns the encoded request message and updated state.
  """
  @spec process_operation(pipeline_state(), Operation.t(), from()) ::
    {:ok, map(), request_id(), pipeline_state()} | {:error, Error.t()}
  def process_operation(state, %Operation{} = operation, from) do
    request_id = ID.generate_request_id()
    
    # Add progress token if needed
    params = add_progress_token(operation.params, operation.progress_opts)
    
    # Create and track request
    request = Request.new(%{
      id: request_id,
      method: operation.method,
      params: params,
      from: from,
      timeout: operation.timeout,
      progress_opts: operation.progress_opts
    })
    
    # Encode the request
    case Message.encode_request(operation.method, params, request_id) do
      {:ok, encoded} ->
        # Track request and set timeout
        updated_state = state
          |> add_request(request)
          |> set_timeout(request)
          
        {:ok, encoded, request_id, updated_state}
        
      error ->
        error
    end
  end

  @doc """
  Processes a batch of operations.
  
  Returns the encoded batch message and updated state.
  """
  @spec process_batch(pipeline_state(), [Operation.t()], from(), String.t()) ::
    {:ok, map(), batch_id(), pipeline_state()} | {:error, Error.t()}
  def process_batch(state, operations, from, protocol_version) do
    if Protocol.supports_feature?(protocol_version, :json_rpc_batching) do
      batch_id = ID.generate_batch_id()
      
      # Build all requests for the batch
      {messages, updated_state} = build_batch_messages(operations, from, batch_id, state)
      
      # Encode as batch
      case Message.encode_batch(messages) do
        {:ok, encoded} ->
          {:ok, encoded, batch_id, updated_state}
          
        error ->
          # Cleanup on error
          cleaned_state = cleanup_batch(batch_id, updated_state)
          {:error, error}
      end
    else
      {:error, Error.protocol(:invalid_request, %{
        message: "Batch operations require protocol version 2025-03-26 or later",
        feature: "batch operations",
        protocol_version: protocol_version,
        required_version: "2025-03-26"
      })}
    end
  end

  @doc """
  Handles a successful response by correlating it with the pending request.
  
  Returns the request that was completed and updated state.
  """
  @spec handle_response(pipeline_state(), request_id(), any()) ::
    {Request.t() | nil, pipeline_state()}
  def handle_response(state, request_id, result) do
    case get_request(state, request_id) do
      nil ->
        {nil, state}
        
      request ->
        # Cancel timeout and remove request
        updated_state = state
          |> cancel_timeout(request_id)
          |> remove_request(request_id)
          
        {request, updated_state}
    end
  end

  @doc """
  Handles an error response.
  """
  @spec handle_error(pipeline_state(), request_id(), Error.t()) ::
    {Request.t() | nil, pipeline_state()}
  def handle_error(state, request_id, error) do
    # Same handling as successful response
    handle_response(state, request_id, error)
  end

  @doc """
  Handles request timeout.
  
  Returns the timed out request and updated state.
  """
  @spec handle_timeout(pipeline_state(), request_id()) ::
    {Request.t() | nil, pipeline_state()}
  def handle_timeout(state, request_id) do
    case get_request(state, request_id) do
      nil ->
        {nil, state}
        
      request ->
        updated_state = remove_request(state, request_id)
        {request, updated_state}
    end
  end

  @doc """
  Cancels a specific request.
  """
  @spec cancel_request(pipeline_state(), request_id()) ::
    {Request.t() | nil, pipeline_state()}
  def cancel_request(state, request_id) do
    handle_timeout(state, request_id)
  end

  @doc """
  Cancels all pending requests.
  
  Returns all cancelled requests and updated state.
  """
  @spec cancel_all_requests(pipeline_state()) ::
    {[Request.t()], pipeline_state()}
  def cancel_all_requests(state) do
    requests = list_pending_requests(state)
    
    # Cancel all timeouts and clear state
    updated_state = Enum.reduce(requests, state, fn request, acc ->
      acc
      |> cancel_timeout(request.id)
      |> remove_request(request.id)
    end)
    
    {requests, %{updated_state | pending_requests: %{}, request_timeouts: %{}}}
  end

  @doc """
  Gets a specific request by ID.
  """
  @spec get_request(pipeline_state(), request_id()) :: Request.t() | nil
  def get_request(state, request_id) do
    Map.get(state.pending_requests, request_id)
  end

  @doc """
  Lists all pending requests.
  """
  @spec list_pending_requests(pipeline_state()) :: [Request.t()]
  def list_pending_requests(state) do
    Map.values(state.pending_requests)
  end

  @doc """
  Checks if a batch is complete (all requests processed).
  """
  @spec batch_complete?(pipeline_state(), batch_id()) :: boolean()
  def batch_complete?(state, batch_id) do
    case Map.get(state.batch_requests, batch_id, []) do
      [] -> true
      request_ids ->
        # Check if any requests are still pending
        not Enum.any?(request_ids, &Map.has_key?(state.pending_requests, &1))
    end
  end

  @doc """
  Gets all requests for a batch.
  """
  @spec get_batch_requests(pipeline_state(), batch_id()) :: [Request.t()]
  def get_batch_requests(state, batch_id) do
    request_ids = Map.get(state.batch_requests, batch_id, [])
    
    request_ids
    |> Enum.map(&get_request(state, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Adds progress token to request params if progress tracking is enabled.
  """
  @spec add_progress_token(map(), map() | nil) :: map()
  def add_progress_token(params, nil), do: params
  def add_progress_token(params, %{token: token}) when not is_nil(token) do
    Map.put(params, "progressToken", token)
  end
  def add_progress_token(params, _), do: params

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp add_request(state, %Request{} = request) do
    %{state | pending_requests: Map.put(state.pending_requests, request.id, request)}
  end

  defp remove_request(state, request_id) do
    # Remove from pending requests
    updated_requests = Map.delete(state.pending_requests, request_id)
    
    # Remove from batch tracking if part of a batch
    updated_batches = 
      state.batch_requests
      |> Enum.map(fn {batch_id, request_ids} ->
        {batch_id, Enum.reject(request_ids, &(&1 == request_id))}
      end)
      |> Enum.reject(fn {_, ids} -> Enum.empty?(ids) end)
      |> Map.new()
    
    %{state | 
      pending_requests: updated_requests,
      batch_requests: updated_batches
    }
  end

  defp set_timeout(state, %Request{} = request) do
    # Schedule timeout message
    timeout_ref = Process.send_after(self(), {:request_timeout, request.id}, request.timeout)
    
    %{state | request_timeouts: Map.put(state.request_timeouts, request.id, timeout_ref)}
  end

  defp cancel_timeout(state, request_id) do
    case Map.get(state.request_timeouts, request_id) do
      nil ->
        state
        
      ref ->
        Process.cancel_timer(ref)
        %{state | request_timeouts: Map.delete(state.request_timeouts, request_id)}
    end
  end

  defp build_batch_messages(operations, from, batch_id, state) do
    {messages, final_state} = 
      Enum.reduce(operations, {[], state}, fn operation, {msgs, current_state} ->
        request_id = ID.generate_request_id()
        
        # Add progress token if needed
        params = add_progress_token(operation.params, operation.progress_opts)
        
        # Create request with batch ID
        request = Request.new(%{
          id: request_id,
          method: operation.method,
          params: params,
          from: from,
          timeout: operation.timeout,
          batch_id: batch_id,
          progress_opts: operation.progress_opts
        })
        
        # Create message
        message = %{
          "jsonrpc" => "2.0",
          "method" => operation.method,
          "params" => params,
          "id" => request_id
        }
        
        # Track request
        new_state = current_state
          |> add_request(request)
          |> set_timeout(request)
          |> track_batch_request(batch_id, request_id)
        
        {[message | msgs], new_state}
      end)
    
    {Enum.reverse(messages), final_state}
  end

  defp track_batch_request(state, batch_id, request_id) do
    existing_ids = Map.get(state.batch_requests, batch_id, [])
    updated_batches = Map.put(state.batch_requests, batch_id, [request_id | existing_ids])
    
    %{state | batch_requests: updated_batches}
  end

  defp cleanup_batch(batch_id, state) do
    request_ids = Map.get(state.batch_requests, batch_id, [])
    
    # Remove all requests and cancel their timeouts
    Enum.reduce(request_ids, state, fn request_id, acc ->
      acc
      |> cancel_timeout(request_id)
      |> remove_request(request_id)
    end)
  end
end