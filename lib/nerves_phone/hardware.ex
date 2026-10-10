defmodule NervesPhone.Hardware do
  @moduledoc """
  Where the phone's hardware (`fp3_extras`) meets the UI's state: the
  functions `NervesPhone.Application` hands to `Fp3Extras.Screen`,
  `Fp3Extras.Orientation` and `Fp3Extras.Buttons`, which turn what they
  report into events for the `:device` controller
  (`NervesPhone.State.Device`).
  """

  require Logger

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

  @doc """
  The screen has been black for the time set in Settings › Display:
  suspend the phone (`Fp3Extras.Sleep`) until the power button, the USB
  cable or the charger wakes it. Called by `Fp3Extras.Screen` in a process
  of its own, and returns once the phone is awake and Wi-Fi is back (or
  given up on). The screen stays black: the power button that wakes the
  phone is also a tap, which brightens it, while a charger wake leaves it
  dark and the count towards the next suspend starts over.

  The UI doesn't render while the screen is black, so nothing is drawn
  mid-suspend; there's no RTC alarm, as nothing needs the phone awake on
  a schedule yet.
  """
  def suspend do
    case Fp3Extras.Sleep.sleep() do
      {:ok, wake} ->
        Logger.info(
          "[hardware] woke by #{wake.woke_by} after #{wake.slept_ms} ms, Wi-Fi #{inspect(wake.wifi)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("[hardware] couldn't suspend: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
