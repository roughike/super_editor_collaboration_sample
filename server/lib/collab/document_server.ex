defmodule Collab.DocumentServer do
  use GenServer

  alias Collab.DocumentSupervisor
  alias __MODULE__.State

  require Logger

  defmodule State do
    # Initial state
    defstruct [
      :id,
      version: 0,
      changes: [Delta.Op.insert("Hello world!\n", %{"node_id" => "hello"})],
      contents: [Delta.Op.insert("Hello world!\n", %{"node_id" => "hello"})]
    ]
  end

  # Public API
  # ----------

  # Starts the server.
  #
  # If it has been already started, returns the process id that can be used for
  # communicating with it.
  #
  # We're also starting it with a Supervisor, so that if the server stops or
  # crashes, it will be automatically restarted.
  def open(document_id) do
    case GenServer.whereis(name(document_id)) do
      nil -> DynamicSupervisor.start_child(DocumentSupervisor, {__MODULE__, document_id})
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  def start_link(id), do: GenServer.start_link(__MODULE__, :ok, name: name(id))
  def close(id), do: GenServer.stop(name(id))
  def get_contents(id), do: call(id, :get_contents)
  def update(id, version, change), do: call(id, {:update, version, change})

  # GenServer callbacks
  # -------------------

  # Initializes the server.
  #
  # Sends a `:continue` event which ensures that the initial document is
  # fetched from Superlist backend before clients can start interacting with it.
  @impl true
  def init(id) do
    state = %State{id: id}
    {:ok, state}
  end

  # Returns the current state of the document, and which version it is.
  @impl true
  def handle_call(:get_contents, _from, state) do
    response = Map.take(state, [:version, :contents])
    {:reply, response, state}
  end

  # Applies the given `client_change` to the document and saves the result
  # as a new state for this GenServer.
  @impl true
  def handle_call({:update, client_version, client_change}, _from, state) do
    if client_version > state.version do
      # Client version is bigger than the one on the server.
      #
      # This means that something likely went wrong. We ignore it.
      {:reply, {:error, :server_behind}, state}
    else
      # Check how far behind client is.
      change_count = state.version - client_version

      # Transform the client change against the list of server
      # changes one by one when needed. Will do nothing if the
      # client and server version are the same.
      #
      # Passing in `true` to `Delta.transform` makes the server
      # version take priority over the client version in case of
      # conflicts when applying the transformation.
      transformed_change =
        state.changes
        |> Enum.take(change_count)
        |> Enum.reverse()
        |> Enum.reduce(client_change, &Delta.transform(&1, &2, true))

      new_contents = Delta.compose(state.contents, transformed_change)

      if valid_document?(new_contents) do
        state = %State{
          state
          | version: state.version + 1,
            changes: [transformed_change | state.changes],
            contents: new_contents
        }

        response = %{
          version: state.version,
          change: transformed_change
        }

        {:reply, {:ok, response}, state}
      else
        {:reply, {:error, :document_corrupted}, state}
      end
    end
  end

  # Private Helper Functions
  # ------------------------
  defp call(id, data) do
    with {:ok, pid} <- open(id), do: GenServer.call(pid, data)
  end

  defp name(id), do: {:global, {:doc, id}}

  # Returns `true` if `contents` contains only "insert" operations.
  defp valid_document?(contents) do
    Enum.reject(contents, &Map.has_key?(&1, "insert")) == []
  end
end
