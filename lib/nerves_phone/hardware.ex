defmodule NervesPhone.Hardware do
  @moduledoc """
  Where the phone's hardware (`fp3_extras`) meets the UI's state: the
  functions `NervesPhone.Application` hands to `Fp3Extras.Screen`,
  `Fp3Extras.Orientation` and `Fp3Extras.Buttons`, which turn what they
  report into events for the `:device` controller
  (`NervesPhone.State.Device`).
  """

  @app NervesPhone.State

  @doc "A screen event: the panel going black or coming back, or the display settings."
  def screen_event({:screen, on?}), do: Solve.dispatch(@app, :device, :screen_changed, on?)

  def screen_event({:display, display}),
    do: Solve.dispatch(@app, :device, :display_changed, display)

  @doc "The orientation, its mode and whether there's a sensor."
  def orientation_event(orientation),
    do: Solve.dispatch(@app, :device, :orientation_changed, orientation)

  @doc "A volume button: step the volume and show the overlay."
  def volume_button(direction) do
    level = if direction == :up, do: Fp3Extras.Volume.up(), else: Fp3Extras.Volume.down()
    Solve.dispatch(@app, :device, :volume_changed, level)
  end
end
