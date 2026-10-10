defmodule NervesPhone.State.Device do
  @moduledoc """
  Battery, network and volume for the title bar, the hostname, whether the
  screen is on, the display's settings and light reading (both from
  `Fp3Extras.Screen`), and which way up the UI is
  (`Fp3Extras.Orientation`). The hardware's reports arrive through
  `NervesPhone.Hardware`.

  Checked every few seconds: the battery from the fuel gauge
  (`Fp3Extras.Battery`), the network through `NervesPhone.Net` (both cheap
  reads). On the host there's no battery, so it reports `config
  :nerves_phone, :device_status`, if set.
  """

  use Solve.Controller,
    events: [:screen_changed, :display_changed, :volume_changed, :orientation_changed, :wake]

  alias NervesPhone.{DeviceInfo, Net}

  @poll_ms 5_000
  # The volume overlay stays this long after the last press.
  @volume_overlay_ms 1_500

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :poll)
    # The screen may have started first (as when this controller restarts).
    send(self(), :fetch_display)
    send(self(), :fetch_orientation)

    %{
      battery: nil,
      network: %{kind: :offline, internet: false, bars: nil},
      hostname: DeviceInfo.hostname(),
      screen_on: true,
      display: nil,
      volume: Fp3Extras.Volume.level(),
      volume_steps: Fp3Extras.Volume.steps(),
      # Shown for a moment after the volume buttons change the volume.
      volume_overlay: false,
      volume_overlay_gen: 0,
      orientation: %{orientation: :portrait, mode: :auto, sensor: false}
    }
  end

  def screen_changed(on, state) when is_boolean(on), do: %{state | screen_on: on}

  def display_changed(display, state) when is_map(display), do: %{state | display: display}

  def volume_changed(level, state) when is_integer(level) do
    gen = state.volume_overlay_gen + 1
    Process.send_after(self(), {:hide_volume_overlay, gen}, @volume_overlay_ms)
    %{state | volume: level, volume_overlay: true, volume_overlay_gen: gen}
  end

  def orientation_changed(orientation, state) when is_map(orientation),
    do: %{state | orientation: orientation}

  # A tap on the dark screen's touch catcher (on the host, where there's no
  # touchscreen reader).
  def wake(_payload, state) do
    Fp3Extras.Screen.touch()
    state
  end

  def handle_info({:hide_volume_overlay, gen}, %{volume_overlay_gen: gen} = state),
    do: %{state | volume_overlay: false}

  def handle_info({:hide_volume_overlay, _stale}, state), do: state

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    %{state | battery: battery(), network: Net.status()}
  end

  def handle_info(:fetch_display, state) do
    if GenServer.whereis(Fp3Extras.Screen),
      do: %{state | display: Fp3Extras.Screen.display()},
      else: state
  end

  def handle_info(:fetch_orientation, state) do
    if GenServer.whereis(Fp3Extras.Orientation),
      do: %{state | orientation: Fp3Extras.Orientation.current()},
      else: state
  end

  def handle_info(_message, state), do: state

  if Mix.target() == :host do
    defp battery, do: Application.get_env(:nerves_phone, :device_status, %{})[:battery]
  else
    # The FP3's fuel gauge. Its level is the boot-time estimate (see
    # Fp3Extras.Battery), which is what there is.
    defp battery do
      case Fp3Extras.Battery.read() do
        %{level: level, charging: charging} when is_integer(level) ->
          %{level: level, charging: charging}

        _ ->
          nil
      end
    end
  end
end
