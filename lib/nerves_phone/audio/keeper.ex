defmodule NervesPhone.Audio.Keeper do
  @moduledoc """
  Keeps `NervesPhone.Audio.Pipeline` running without letting it take the app
  down.

  It waits for an audio output device before starting the pipeline: on the
  phone the sound card appears once the ADSP is up, a little after boot.

  A pipeline that crashes over and over would exhaust the application
  supervisor's restart budget and stop the UI with it. The keeper traps the
  exit instead and restarts the pipeline with a growing delay, up to a
  minute.
  """

  use GenServer
  require Logger

  @device_poll_ms 1_000
  @min_backoff_ms 1_000
  @max_backoff_ms 60_000
  # A pipeline that ran this long resets the backoff.
  @stable_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :start)
    {:ok, %{opts: opts, pipeline: nil, backoff: @min_backoff_ms, started_at: nil}}
  end

  @impl GenServer
  def handle_info(:start, state) do
    if output_device?() do
      case NervesPhone.Audio.Pipeline.start_link(state.opts) do
        {:ok, _supervisor, pipeline} ->
          {:noreply, %{state | pipeline: pipeline, started_at: now()}}

        {:error, reason} ->
          retry(state, reason)
      end
    else
      Process.send_after(self(), :start, @device_poll_ms)
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, reason}, %{pipeline: pipeline} = state) when pipeline != nil do
    state =
      if now() - state.started_at > @stable_ms,
        do: %{state | backoff: @min_backoff_ms},
        else: state

    retry(%{state | pipeline: nil}, reason)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp retry(state, reason) do
    Logger.error(
      "[audio] pipeline stopped (#{inspect(reason, limit: 5)}), restarting in #{state.backoff} ms"
    )

    Process.send_after(self(), :start, state.backoff)
    {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff_ms)}}
  end

  defp output_device? do
    Enum.any?(Membrane.PortAudio.list_devices(), &(&1.default_device == :output))
  rescue
    _ -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
end
