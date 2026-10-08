defmodule NervesPhone.Screen do
  @moduledoc """
  The display: brightness, and dimming then turning off when nobody's
  touching it.

  The screen is `:on`, `:dim` or `:off`. Without touches it dims after
  `dim_after_ms` and goes black after `off_after_ms` (both counted from the
  last touch; either can be nil for never). A touch wakes it. Touches are
  reported by `NervesPhone.Buttons`, which reads the touchscreen alongside
  the buttons, through `touch/0`; a tap on the power button turns the
  screen off or on with `toggle/0`.

  Every change of level fades: about a second to dim, a little less from
  there to black, a quarter second to wake, and a short fade when the
  brightness is changed. Levels are percentages, faded in that space and
  written to the panel's `brightness` in `/sys/class/backlight` on a 2.2
  power curve, so a fade looks even and 50% looks like half. Once it's
  black, `bl_power` turns the backlight off.

  With automatic brightness, the level follows `NervesPhone.LightSensor`,
  measured when it's turned on, on waking, and every minute while the
  screen is fully on.

  The settings are saved to `state_dir/display.json`; until then they're
  `config :nerves_phone, :display`. Everything a screen shows about this
  goes to the `:device` controller: `screen_on` (so the UI can skip
  re-rendering while the screen is black, and put a touch catcher over
  everything, as the touch that wakes it shouldn't also press a button)
  and `display`.
  """

  use GenServer
  require Logger

  alias NervesPhone.LightSensor

  @dim_choices [15_000, 30_000, 60_000, 120_000, 300_000, nil]
  @off_choices [30_000, 60_000, 120_000, 300_000, 600_000, nil]

  @defaults %{brightness: 60, auto: false, dim_after_ms: 30_000, off_after_ms: 60_000}

  # Brightness never goes below this (the panel at 0 is black).
  @min_brightness 5
  # The dim level, as a share of the on level.
  @dim_share 0.35

  @check_ms 250
  @tick_ms 20
  @sample_ms 60_000
  @save_ms 1_000

  @fade_ms %{dim: 1_000, off: 800, wake: 250, change: 300, auto: 1_500}

  @doc "Choices for dimming and for turning off, in ms (nil is never)."
  def dim_choices, do: @dim_choices
  def off_choices, do: @off_choices

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Something touched the screen: stay on, or wake up."
  def touch, do: GenServer.cast(__MODULE__, :touch)

  @doc "The power button: turn the screen off, or on."
  def toggle, do: GenServer.cast(__MODULE__, :toggle)

  @doc """
  Changes settings: `:brightness` (#{@min_brightness}..100), `:auto`,
  `:dim_after_ms`, `:off_after_ms`. Dimming at or after turning off would
  never happen, so it's turned off then.
  """
  def put_settings(changes), do: GenServer.cast(__MODULE__, {:put_settings, Map.new(changes)})

  @doc "The settings and light reading, as sent to the `:device` controller."
  def display, do: GenServer.call(__MODULE__, :display)

  @doc """
  Keeps the screen on while the calling process wants it (a video playing,
  say): until `keep_awake(false)`, or the process exits.
  """
  def keep_awake(awake?) when is_boolean(awake?),
    do: GenServer.cast(__MODULE__, {:keep_awake, self(), awake?})

  @doc "Measures the light now (for automatic brightness)."
  def measure, do: GenServer.cast(__MODULE__, :measure)

  # ---------- Server ----------

  @impl GenServer
  def init(_opts) do
    send(self(), :check)

    backlight = backlight()

    state = %{
      settings: load(),
      mode: :on,
      last_touch: now(),
      backlight: backlight,
      max_raw: max_raw(backlight),
      written: nil,
      # The level shown now, and the fade under way, if any.
      level: 100.0,
      fade: nil,
      light: nil,
      light_error: nil,
      auto_level: nil,
      measuring: false,
      measured_at: nil,
      save_timer: nil,
      # Processes keeping the screen on, by monitor.
      awake: %{}
    }

    state = state |> maybe_measure() |> fade_to(on_level(state), :change)
    {:ok, publish(state)}
  end

  @impl GenServer
  def handle_call(:display, _from, state), do: {:reply, display(state), state}

  @impl GenServer
  def handle_cast(:touch, state) do
    state = %{state | last_touch: now()}
    {:noreply, if(state.mode == :on, do: state, else: wake(state))}
  end

  def handle_cast(:toggle, state) do
    state = %{state | last_touch: now()}

    {:noreply,
     if(state.mode == :off, do: wake(state), else: %{state | mode: :off} |> fade_to(0, :off))}
  end

  def handle_cast({:put_settings, changes}, state) do
    settings = state.settings |> Map.merge(Map.take(changes, Map.keys(@defaults))) |> validate()
    # Dragging the slider changes the brightness many times a second, so
    # save once it settles.
    if state.save_timer, do: Process.cancel_timer(state.save_timer)
    state = %{state | save_timer: Process.send_after(self(), :save, @save_ms)}
    turned_auto_on? = settings.auto and not state.settings.auto
    state = %{state | settings: settings, last_touch: now()}
    state = if turned_auto_on?, do: measure_now(state), else: state

    state =
      case state.mode do
        :on -> fade_to(state, on_level(state), :change)
        _ -> wake(state)
      end

    {:noreply, publish(state)}
  end

  def handle_cast({:keep_awake, pid, true}, state) do
    if pid in Map.values(state.awake) do
      {:noreply, state}
    else
      state = %{state | awake: Map.put(state.awake, Process.monitor(pid), pid)}
      {:noreply, if(state.mode == :on, do: state, else: wake(state))}
    end
  end

  def handle_cast({:keep_awake, pid, false}, state) do
    awake =
      for {ref, ^pid} <- state.awake, reduce: state.awake do
        acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
      end

    {:noreply, %{state | awake: awake, last_touch: now()}}
  end

  def handle_cast(:measure, state), do: {:noreply, state |> measure_now() |> publish()}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | awake: Map.delete(state.awake, ref), last_touch: now()}}

  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    # Something wants the screen on: count it as touched.
    state = if state.awake == %{}, do: state, else: %{state | last_touch: now()}
    idle = now() - state.last_touch
    %{dim_after_ms: dim_after, off_after_ms: off_after} = state.settings

    state =
      cond do
        state.mode != :off and off_after != nil and idle >= off_after ->
          %{state | mode: :off} |> fade_to(0, :off)

        state.mode == :on and dim_after != nil and idle >= dim_after ->
          %{state | mode: :dim} |> fade_to(dim_level(state), :dim)

        state.mode == :on ->
          maybe_measure(state)

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:save, state) do
    save(state.settings)
    {:noreply, %{state | save_timer: nil}}
  end

  def handle_info(:tick, %{fade: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{fade: fade} = state) do
    t = min((now() - fade.start) / fade.duration, 1.0)
    # Ease in and out.
    eased = t * t * (3 - 2 * t)
    state = write(%{state | level: fade.from + (fade.to - fade.from) * eased})

    if t >= 1.0 do
      state = %{state | fade: nil}
      {:noreply, if(state.mode == :off, do: power(state, false), else: state)}
    else
      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, state}
    end
  end

  def handle_info({:measured, result}, state) do
    state = %{state | measuring: false, measured_at: now()}

    state =
      case result do
        {:ok, light} ->
          level = @min_brightness + LightSensor.level(light) * (100 - @min_brightness)
          state = %{state | light: light, light_error: nil, auto_level: level}
          if state.mode == :on, do: fade_to(state, on_level(state), :auto), else: state

        {:error, reason} ->
          Logger.info("[screen] light measurement failed: #{inspect(reason)}")
          %{state | light_error: reason}
      end

    {:noreply, publish(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------- Levels ----------

  defp on_level(%{settings: %{auto: true}, auto_level: level}) when level != nil, do: level
  defp on_level(state), do: state.settings.brightness / 1

  defp dim_level(state) do
    on = on_level(state)
    min(on, max(on * @dim_share, @min_brightness / 2))
  end

  defp wake(state) do
    state = if state.mode == :off, do: power(state, true), else: state
    %{state | mode: :on} |> fade_to(on_level(state), :wake) |> maybe_measure()
  end

  defp fade_to(state, level, kind) do
    if state.fade == nil, do: send(self(), :tick)

    %{
      state
      | fade: %{from: state.level, to: level / 1, start: now(), duration: @fade_ms[kind]}
    }
  end

  # ---------- Light ----------

  # On waking, and every minute while on, if automatic.
  defp maybe_measure(%{settings: %{auto: true}, measuring: false} = state) do
    if state.measured_at == nil or now() - state.measured_at >= @sample_ms,
      do: measure_now(state),
      else: state
  end

  defp maybe_measure(state), do: state

  defp measure_now(%{measuring: true} = state), do: state

  defp measure_now(state) do
    screen = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(screen, {:measured, LightSensor.measure()})
    end)

    %{state | measuring: true}
  end

  # ---------- The panel ----------

  # A 2.2 power curve from percent to the panel's raw level.
  defp write(%{backlight: nil} = state), do: state

  defp write(state) do
    raw =
      if state.level <= 0,
        do: 0,
        else: max(1, round(state.max_raw * :math.pow(state.level / 100, 2.2)))

    if raw != state.written, do: File.write(Path.join(state.backlight, "brightness"), "#{raw}")
    %{state | written: raw}
  end

  defp power(state, on) do
    if state.backlight do
      if on, do: File.write(Path.join(state.backlight, "brightness"), "0")
      File.write(Path.join(state.backlight, "bl_power"), if(on, do: "0", else: "4"))
    end

    Solve.dispatch(NervesPhone.State, :device, :screen_changed, on)
    %{state | written: if(on, do: 0, else: state.written)}
  end

  defp backlight do
    case Path.wildcard("/sys/class/backlight/*") do
      [path | _] -> path
      [] -> nil
    end
  end

  defp max_raw(nil), do: 100

  defp max_raw(backlight) do
    with {:ok, text} <- File.read(Path.join(backlight, "max_brightness")),
         {max, _} <- Integer.parse(text) do
      max
    else
      _ -> 255
    end
  end

  # ---------- Settings ----------

  defp publish(state) do
    Solve.dispatch(NervesPhone.State, :device, :display_changed, display(state))
    state
  end

  defp display(state) do
    Map.merge(state.settings, %{
      level: round(on_level(state)),
      light: state.light && LightSensor.describe(state.light),
      light_error: state.light_error,
      measuring: state.measuring
    })
  end

  defp validate(settings) do
    brightness = settings.brightness |> round() |> max(@min_brightness) |> min(100)

    dim =
      if settings.dim_after_ms in @dim_choices,
        do: settings.dim_after_ms,
        else: @defaults.dim_after_ms

    off =
      if settings.off_after_ms in @off_choices,
        do: settings.off_after_ms,
        else: @defaults.off_after_ms

    dim = if dim != nil and off != nil and dim >= off, do: nil, else: dim

    %{
      settings
      | brightness: brightness,
        auto: settings.auto == true,
        dim_after_ms: dim,
        off_after_ms: off
    }
  end

  defp path, do: Path.join(NervesPhone.state_dir(), "display.json")

  defp load do
    defaults = Map.merge(@defaults, Map.new(Application.get_env(:nerves_phone, :display, [])))

    saved =
      with {:ok, json} <- File.read(path()),
           {:ok, map} when is_map(map) <- JSON.decode(json) do
        for {key, value} <- map,
            atom = Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key)),
            into: %{},
            do: {atom, value}
      else
        _ -> %{}
      end

    defaults |> Map.merge(saved) |> validate()
  end

  defp save(settings) do
    File.mkdir_p(NervesPhone.state_dir())
    File.write(path(), JSON.encode!(settings))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
