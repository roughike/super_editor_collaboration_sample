defmodule CollabWeb.DocumentChannel do
  use Phoenix.Channel

  alias Collab.DocumentServer

  require Logger

  @impl true
  def join("document:" <> id, _message, socket) do
    {:ok, _pid} = DocumentServer.open(id)

    socket = assign(socket, :document_id, id)
    send(self(), :after_join)
    {:ok, %{channel: "document:#{id}"}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Get the current state of the document and push it to the user.
    document = DocumentServer.get_contents(socket.assigns.document_id)
    push(socket, "open", document)
    {:noreply, socket}
  end

  # The document has been updated by a client locally.
  #
  # We try to update it on the document server and broadcast the
  # needed set of changes to other clients, so that they can get
  # their local versions up to date.
  @impl true
  def handle_in("update", %{"version" => version, "change" => change}, socket) do
    case DocumentServer.update(socket.assigns.document_id, version, change) do
      {:ok, response} ->
        # Notify others (but not the client who updated the document)
        # about the document change.
        broadcast_from!(socket, "update", response)
        {:reply, :ok, socket}

      {:error, :document_corrupted} ->
        # The document was corrupted for some reason.
        {:reply, {:error, %{"reason" => "document_corrupted"}}, socket}

      error ->
        Logger.error("Couldn't update document due to unknown reason. #{inspect(error)}")
        {:reply, {:error, %{"reason" => inspect(error)}}, socket}
    end
  end
end
