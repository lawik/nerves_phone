defmodule NervesPhone.Screen do
  @moduledoc """
  Turns the display off after a while without touches, and back on at the
  next touch.

  Touches are reported by `NervesPhone.Buttons`, which reads the
  touchscreen alongside the buttons, through `touch/0`. The backlight is
  the panel's `bl_power` in `/sys/class/backlight` (4 is off, 0 on).

  The state goes to the `:device` controller, so the UI can skip
  re-rendering while the screen is dark and put a touch catcher over
  everything: the touch that wakes the screen shouldn't also press a
  button.

  `config :nerves_phone, screen_timeout_ms: ...` sets the delay; nil never
  turns the screen off (the host's default).
  """

  use GenServer

  @check_ms 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Something touched the screen: stay on, or wake up."
  def touch, do: GenServer.cast(__MODULE__, :touch)

  @impl GenServer
  def init(_opts) do
    timeout = Application.get_env(:nerves_phone, :screen_timeout_ms)
    if timeout, do: Process.send_after(self(), :check, @check_ms)
    {:ok, %{timeout: timeout, last_touch: now(), on: true, backlight: backlight()}}
  end

  @impl GenServer
  def handle_cast(:touch, state) do
    state = %{state | last_touch: now()}
    {:noreply, if(state.on, do: state, else: set(state, true))}
  end

  @impl GenServer
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    asleep? = now() - state.last_touch >= state.timeout
    {:noreply, if(state.on and asleep?, do: set(state, false), else: state)}
  end

  defp set(state, on) do
    if state.backlight, do: File.write(state.backlight, if(on, do: "0", else: "4"))
    Solve.dispatch(NervesPhone.State, :device, :screen_changed, on)
    %{state | on: on}
  end

  defp backlight do
    case Path.wildcard("/sys/class/backlight/*/bl_power") do
      [path | _] -> path
      [] -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
