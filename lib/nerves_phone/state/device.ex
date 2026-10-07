defmodule NervesPhone.State.Device do
  @moduledoc """
  Battery and network status for the title bar, and whether the screen is
  on (see `NervesPhone.Screen`).

  Checked every few seconds: the battery from the fuel gauge in sysfs, the
  network from VintageNet's properties (both cheap reads). On the host there
  is neither, so it reports `config :nerves_phone, :device_status`, if set.
  """

  use Solve.Controller, events: [:screen_changed, :wake]

  @poll_ms 5_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :poll)
    %{battery: nil, network: %{kind: :offline, internet: false, bars: nil}, screen_on: true}
  end

  def screen_changed(on, state) when is_boolean(on), do: %{state | screen_on: on}

  # A tap on the dark screen's touch catcher (on the host, where there's no
  # touchscreen reader).
  def wake(_payload, state) do
    NervesPhone.Screen.touch()
    state
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    Map.merge(state, read())
  end

  def handle_info(_message, state), do: state

  if Mix.target() == :host do
    defp read do
      Application.get_env(:nerves_phone, :device_status) ||
        %{battery: nil, network: %{kind: :offline, internet: false, bars: nil}}
    end
  else
    defp read, do: %{battery: battery(), network: network()}

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

    # The best interface wins: Wi-Fi, then cellular, then wired, then USB.
    defp network do
      candidates = [
        {:wifi, "wlan0"},
        {:cellular, "rmnet0"},
        {:ethernet, "eth0"},
        {:usb, "usb0"}
      ]

      states =
        for {kind, ifname} <- candidates,
            conn = VintageNet.get(["interface", ifname, "connection"]),
            conn in [:internet, :lan],
            do: {kind, ifname, conn}

      case Enum.find(states, &(elem(&1, 2) == :internet)) || List.first(states) do
        nil ->
          %{kind: :offline, internet: false, bars: nil}

        {kind, ifname, conn} ->
          %{kind: kind, internet: conn == :internet, bars: bars(kind, ifname)}
      end
    end

    defp bars(:wifi, ifname) do
      case VintageNet.get(["interface", ifname, "wifi", "current_ap"]) do
        %{signal_percent: percent} when is_integer(percent) -> min(div(percent, 25) + 1, 4)
        _ -> nil
      end
    end

    defp bars(:cellular, ifname) do
      case VintageNet.get(["interface", ifname, "mobile", "signal_4bars"]) do
        bars when is_integer(bars) -> bars
        _ -> nil
      end
    end

    defp bars(_kind, _ifname), do: nil
  end
end
