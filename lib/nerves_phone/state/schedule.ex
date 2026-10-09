defmodule NervesPhone.State.Schedule do
  @moduledoc """
  Which apps can be used now, by `NervesPhone.Schedule`. Looks again at
  the start of each minute, and when the schedule's changed.

  The shell (`NervesPhone.State.Shell`) depends on it for what it opens
  and shows, and is told to close the app on screen when it stops being
  available.

  Exposes `available` (app modules), and the `schedule` itself, for
  phone_remote.
  """

  use Solve.Controller, events: [:changed]

  alias NervesPhone.Schedule

  @impl Solve.Controller
  def init(_params, _dependencies) do
    tick()
    schedule = Schedule.get()
    %{schedule: schedule, available: Schedule.available(schedule)}
  end

  def changed(schedule, state), do: refresh(%{state | schedule: schedule})

  def handle_info(:tick, state) do
    tick()
    refresh(state)
  end

  def handle_info(_message, state), do: state

  defp refresh(state) do
    available = Schedule.available(state.schedule)

    if available != state.available do
      Solve.dispatch(NervesPhone.State, :shell, :available_changed, available)
    end

    %{state | available: available}
  end

  # Just after the next minute starts.
  defp tick do
    ms = 60_000 - rem(System.os_time(:millisecond), 60_000) + 100
    Process.send_after(self(), :tick, ms)
  end
end
