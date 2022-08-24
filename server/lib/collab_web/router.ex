defmodule CollabWeb.Router do
  use CollabWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", CollabWeb do
    pipe_through :api
  end
end
