# input_event is only in phone builds.
if Mix.target() != :host do
  defmodule NervesPhone.Buttons do
    @moduledoc """
    The phone's hardware buttons:

      * volume up / down step the volume (holding repeats)
      * a tap on the power button toggles play/pause
      * a wired headset's play/pause button does the same

    It also watches the touchscreen and tells `NervesPhone.Screen` about
    touches, which keeps the screen on or wakes it.

    Reads the input devices with `input_event` (Emerge reads the same devices
    for touch, which is fine: evdev hands events to every reader) and turns
    key presses into events on the `:player` controller. Runs in its own
    process, so a busy UI never delays a button.
    """

    use GenServer
    require Logger

    # A power press held longer than this isn't a tap.
    @tap_ms 600

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(_opts) do
      send(self(), :open)
      {:ok, %{power_down_at: nil}}
    end

    @impl GenServer
    def handle_info(:open, state) do
      keys = [:key_volumeup, :key_volumedown, :key_power, :key_playpause]

      devices =
        for {path, info} <- InputEvent.enumerate(),
            kind = kind(info, keys),
            kind != nil,
            match?({:ok, _}, InputEvent.start_link(path: path)),
            into: %{},
            do: {path, kind}

      if not Enum.any?(devices, fn {_, kind} -> kind == :buttons end) do
        Logger.warning("[buttons] no button devices found")
      end

      {:noreply, Map.put(state, :devices, devices)}
    end

    def handle_info({:input_event, path, events}, state) when is_list(events) do
      case state.devices[path] do
        :touchscreen ->
          NervesPhone.Screen.touch()
          {:noreply, state}

        _buttons ->
          {:noreply, Enum.reduce(events, state, &handle_key/2)}
      end
    end

    def handle_info(_message, state), do: {:noreply, state}

    # Value 1 is a press, 2 a key repeat while held, 0 a release.
    defp handle_key({:ev_key, key, value}, state)
         when key in [:key_volumeup, :key_volumedown] and value in [1, 2] do
      dispatch(if key == :key_volumeup, do: :volume_up, else: :volume_down)
      state
    end

    defp handle_key({:ev_key, :key_power, 1}, state), do: %{state | power_down_at: now()}

    defp handle_key({:ev_key, :key_power, 0}, %{power_down_at: down_at} = state)
         when down_at != nil do
      if now() - down_at <= @tap_ms, do: dispatch(:toggle_play)
      %{state | power_down_at: nil}
    end

    defp handle_key({:ev_key, :key_playpause, 1}, state) do
      dispatch(:toggle_play)
      state
    end

    defp handle_key(_event, state), do: state

    defp kind(info, keys) do
      cond do
        Keyword.has_key?(info.report_info[:ev_abs] || [], :abs_mt_position_x) -> :touchscreen
        Enum.any?(info.report_info[:ev_key] || [], &(&1 in keys)) -> :buttons
        true -> nil
      end
    end

    defp dispatch(event), do: Solve.dispatch(NervesPhone.State, :player, event, nil)

    defp now, do: System.monotonic_time(:millisecond)
  end
end
