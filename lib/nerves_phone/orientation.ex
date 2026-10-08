defmodule NervesPhone.Orientation do
  @moduledoc """
  Which way up the phone is held, for the UI to turn with it.

  The orientation is `:portrait`, `:landscape_left` (the top of the phone
  pointing left, turned counter-clockwise) or `:landscape_right`. Upside
  down isn't used, like on most phones.

  How it's picked is the `mode`, set in Settings › Display:

    * `:auto` - follows the accelerometer (`ExQcomSmgr`), read four times
      a second. A new orientation has to hold for half a second, and the
      phone has to be tilted well into it (within 30° of upright or
      sideways), so it doesn't flip back and forth at 45°. Lying flat
      keeps the orientation it had.
    * `:portrait` or `:landscape` - locked. Landscape is the side the
      phone was last turned to, or left.

  On the host there's no accelerometer, so `:auto` stays portrait and the
  locked modes are how landscape is tried out.

  The mode is saved to `state_dir/orientation.json`. Changes go to the
  `:device` controller as `orientation`.

  ## Axes

  Orientation is worked out in the screen's axes: x to its right, y to
  its top, and readings the reaction to gravity (y is +9.8 m/s² held
  upright). The sensor may be mounted turned, so `config :nerves_phone,
  :orientation, axes: [x: {:y, 1}, y: {:x, 1}]` says which sensor axis,
  and which way, each screen axis is. The default is the sensor's own.
  """

  use GenServer

  @compile {:no_warn_undefined, ExQcomSmgr}

  @poll_ms 250
  # Readings in a row a new orientation needs (half a second).
  @settle 2
  @gravity 9.81

  @type orientation :: :portrait | :landscape_left | :landscape_right
  @type mode :: :auto | :portrait | :landscape

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The orientation, the mode, and whether there's an accelerometer."
  @spec current() :: %{orientation: orientation(), mode: mode(), sensor: boolean()}
  def current, do: GenServer.call(__MODULE__, :current)

  @doc "Sets how the orientation is picked, and saves it."
  @spec put_mode(mode()) :: :ok
  def put_mode(mode) when mode in [:auto, :portrait, :landscape],
    do: GenServer.cast(__MODULE__, {:put_mode, mode})

  @doc """
  The orientation a reading points to, or nil when it's too flat or too
  close to a diagonal to tell. `reading` is the reaction to gravity in
  Android's axes: x to the right of the screen, y to its top, z out of it.
  """
  @spec classify(%{x: number(), y: number()}) :: orientation() | :upside_down | nil
  def classify(%{x: x, y: y}) do
    # Mostly flat: the screen faces up or down, so there's no up.
    if :math.sqrt(x * x + y * y) < 0.45 * @gravity do
      nil
    else
      angle = :math.atan2(x, y) * 180 / :math.pi()

      cond do
        abs(angle) <= 30 -> :portrait
        abs(angle - 90) <= 30 -> :landscape_left
        abs(angle + 90) <= 30 -> :landscape_right
        abs(angle) >= 150 -> :upside_down
        true -> nil
      end
    end
  end

  @impl GenServer
  def init(_opts) do
    sensor = Code.ensure_loaded?(ExQcomSmgr)
    mode = load_mode()

    state = %{
      mode: mode,
      sensor: sensor,
      # What the accelerometer says, settled, and the side last seen.
      sensed: :portrait,
      landscape: :landscape_left,
      candidate: nil,
      count: 0,
      orientation: :portrait
    }

    if sensor, do: send(self(), :poll)
    {:ok, publish(%{state | orientation: effective(state)})}
  end

  @impl GenServer
  def handle_call(:current, _from, state),
    do: {:reply, Map.take(state, [:orientation, :mode, :sensor]), state}

  @impl GenServer
  def handle_cast({:put_mode, mode}, state) do
    save_mode(mode)
    {:noreply, update(%{state | mode: mode})}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)

    case ExQcomSmgr.read(:accel) do
      {:ok, reading} -> {:noreply, sense(state, classify(reaction(reading)))}
      {:error, _reason} -> {:noreply, state}
    end
  end

  # A reading counts once it's held for @settle polls in a row.
  defp sense(state, sensed) when sensed in [:portrait, :landscape_left, :landscape_right] do
    count = if sensed == state.candidate, do: state.count + 1, else: 1

    if count >= @settle and sensed != state.sensed do
      landscape = if sensed == :portrait, do: state.landscape, else: sensed
      update(%{state | sensed: sensed, landscape: landscape, candidate: sensed, count: count})
    else
      %{state | candidate: sensed, count: count}
    end
  end

  defp sense(state, _flat_or_upside_down), do: %{state | candidate: nil, count: 0}

  defp effective(%{mode: :auto, sensor: true, sensed: sensed}), do: sensed
  defp effective(%{mode: :auto}), do: :portrait
  defp effective(%{mode: :portrait}), do: :portrait
  defp effective(%{mode: :landscape, landscape: side}), do: side

  # Published on every change, as the mode shows in Settings even when
  # the orientation stays the same.
  defp update(state), do: publish(%{state | orientation: effective(state)})

  defp publish(state) do
    Solve.dispatch(
      NervesPhone.State,
      :device,
      :orientation_changed,
      Map.take(state, [:orientation, :mode, :sensor])
    )

    state
  end

  # The reading in the screen's axes.
  defp reaction(reading) do
    axes = Application.get_env(:nerves_phone, :orientation, [])[:axes] || []
    {x_axis, x_sign} = Keyword.get(axes, :x, {:x, 1})
    {y_axis, y_sign} = Keyword.get(axes, :y, {:y, 1})
    %{x: x_sign * Map.fetch!(reading, x_axis), y: y_sign * Map.fetch!(reading, y_axis)}
  end

  defp path, do: Path.join(NervesPhone.state_dir(), "orientation.json")

  defp load_mode do
    with {:ok, json} <- File.read(path()),
         {:ok, %{"mode" => mode}} when mode in ~w(auto portrait landscape) <- JSON.decode(json) do
      String.to_existing_atom(mode)
    else
      _none -> Application.get_env(:nerves_phone, :orientation, [])[:mode] || :auto
    end
  end

  defp save_mode(mode) do
    File.mkdir_p!(NervesPhone.state_dir())
    File.write(path(), JSON.encode!(%{mode: mode}))
  end
end
