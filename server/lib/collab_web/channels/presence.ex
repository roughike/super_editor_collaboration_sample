defmodule CollabWeb.Presence do
  use Phoenix.Presence,
    otp_app: :collab,
    pubsub_server: Collab.PubSub
end
