defmodule NervesPhone.State.Shell do
  @moduledoc """
  Which app is on screen, or nil for the home screen.
  """

  use Solve.Controller, events: [:open, :home]

  alias NervesPhone.App

  @impl Solve.Controller
  def init(_params, _dependencies), do: %{active: nil}

  def open(app, state) do
    if app in App.all() do
      if function_exported?(app, :opened, 0), do: app.opened()
      %{state | active: app}
    else
      state
    end
  end

  def home(_payload, state), do: %{state | active: nil}
end
