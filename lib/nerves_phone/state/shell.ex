defmodule NervesPhone.State.Shell do
  @moduledoc """
  Which app is on screen, or nil for the home screen, and which apps can
  be opened now (`NervesPhone.State.Schedule`). An app that stops being
  available while it's open is closed.
  """

  use Solve.Controller, events: [:open, :home, :available_changed]

  alias NervesPhone.App

  @impl Solve.Controller
  def init(_params, _dependencies), do: %{active: nil}

  @impl Solve.Controller
  def expose(state, dependencies, _params) do
    %{active: state.active, available: available(dependencies)}
  end

  def open(app, state, dependencies) do
    if app in App.all() and app in available(dependencies) do
      if function_exported?(app, :opened, 0), do: app.opened()
      %{state | active: app}
    else
      state
    end
  end

  def home(_payload, state), do: %{state | active: nil}

  def available_changed(available, %{active: active} = state) do
    if active != nil and active not in available do
      if function_exported?(active, :closed, 0), do: active.closed()
      %{state | active: nil}
    else
      state
    end
  end

  # Everything, until the schedule's known.
  defp available(dependencies) do
    case dependencies[:schedule] do
      %{available: available} -> available
      nil -> App.all()
    end
  end
end
