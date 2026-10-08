defmodule NervesPhone.State.Device do
  @moduledoc """
  Battery, network and volume for the title bar, the hostname, whether the
  screen is on, the display's settings and light reading (both from
  `NervesPhone.Screen`), and which way up the UI is
  (`NervesPhone.Orientation`).

  Checked every few seconds: the battery from the fuel gauge in sysfs, the
  network through `NervesPhone.Net` (both cheap reads). On the host there's
  no battery, so it reports `config :nerves_phone, :device_status`, if set.
  """

  use Solve.Controller,
    events: [:screen_changed, :display_changed, :volume_changed, :orientation_changed, :wake]

  alias NervesPhone.{DeviceInfo, Net}

  @poll_ms 5_000

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
      volume: NervesPhone.Audio.Volume.level(),
      volume_steps: NervesPhone.Audio.Volume.steps(),
      orientation: %{orientation: :portrait, mode: :auto, sensor: false}
    }
  end

  def screen_changed(on, state) when is_boolean(on), do: %{state | screen_on: on}

  def display_changed(display, state) when is_map(display), do: %{state | display: display}

  def volume_changed(level, state) when is_integer(level), do: %{state | volume: level}

  def orientation_changed(orientation, state) when is_map(orientation),
    do: %{state | orientation: orientation}

  # A tap on the dark screen's touch catcher (on the host, where there's no
  # touchscreen reader).
  def wake(_payload, state) do
    NervesPhone.Screen.touch()
    state
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    %{state | battery: battery(), network: Net.status()}
  end

  def handle_info(:fetch_display, state) do
    if GenServer.whereis(NervesPhone.Screen),
      do: %{state | display: NervesPhone.Screen.display()},
      else: state
  end

  def handle_info(:fetch_orientation, state) do
    if GenServer.whereis(NervesPhone.Orientation),
      do: %{state | orientation: NervesPhone.Orientation.current()},
      else: state
  end

  def handle_info(_message, state), do: state

  if Mix.target() == :host do
    defp battery, do: Application.get_env(:nerves_phone, :device_status, %{})[:battery]
  else
    # The FP3's fuel gauge.
    defp battery do
      with [dir | _] <- Path.wildcard("/sys/class/power_supply/qg-battery*"),
           {:ok, capacity} <- File.read(Path.join(dir, "capacity")),
           {level, _} <- Integer.parse(capacity) do
        status =
          Path.join(dir, "status") |> File.read() |> elem(1) |> to_string() |> String.trim()

        %{level: level, charging: status in ["Charging", "Full"]}
      else
        _ -> nil
      end
    end
  end
end
