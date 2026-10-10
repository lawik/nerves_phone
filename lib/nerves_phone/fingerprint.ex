# circuits_gpio is only in phone builds.
if Mix.target() != :host do
  defmodule NervesPhone.Fingerprint do
    @moduledoc """
    Experiment: can the rear fingerprint sensor act as a touch button?

    The sensor is an Elan part on an SPI bus (GPIO 135-138) that TrustZone
    owns, so Linux can never read it. What Linux does own are the three
    sideband lines Android's `elan_fp_qcom_tee` driver drives:

      * GPIO 90  - sensor VDD enable (low at boot: the sensor is off)
      * GPIO 140 - reset, active low
      * GPIO 48  - interrupt from the sensor, rising edge on Android

    `watch/0` powers the sensor, pulses reset the way the Android driver
    does, and logs every edge on GPIO 48. If the chip raises its IRQ on
    finger contact without any SPI setup, touches show up here. If it
    needs SPI first, the line stays quiet and the experiment is over.

    `off/0` powers the sensor back down and releases the lines.

    Result on 2026-10-10: nothing. GPIO 48 reads low with the internal
    pull-up, pull-down or no pull, sensor powered or not, and never moved
    on touches or on reset pulses. Something on that net holds it low, and
    the chip raises no interrupt without SPI configuration it can only get
    from the TrustZone app. Kept as a harness in case a different reset or
    power sequence turns out to matter.
    """

    use GenServer
    require Logger

    @chip "gpiochip0"
    @vdd 90
    @reset 140
    @irq 48

    @doc "Power the sensor, reset it and start logging edges on GPIO 48."
    def watch, do: GenServer.start(__MODULE__, [], name: __MODULE__)

    @doc "Power the sensor down and release the GPIO lines."
    def off do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end

    @doc "Edges seen so far, newest first, as `{monotonic_ns, value}`."
    def events, do: GenServer.call(__MODULE__, :events)

    @doc "Current level of the IRQ line."
    def irq, do: GenServer.call(__MODULE__, :irq)

    @doc "Pulse reset again (low 5 ms, then 50 ms to settle)."
    def reset, do: GenServer.call(__MODULE__, :reset)

    @impl GenServer
    def init(_) do
      with {:ok, vdd} <- Circuits.GPIO.open({@chip, @vdd}, :output, initial_value: 1),
           {:ok, rst} <- Circuits.GPIO.open({@chip, @reset}, :output, initial_value: 1),
           {:ok, irq} <- Circuits.GPIO.open({@chip, @irq}, :input, pull_mode: :pulldown),
           :ok <- Circuits.GPIO.set_interrupts(irq, :both) do
        Process.sleep(10)
        pulse_reset(rst)

        Logger.info("[fingerprint] sensor powered, irq line is #{Circuits.GPIO.read(irq)}")
        {:ok, %{vdd: vdd, rst: rst, irq: irq, events: []}}
      else
        error ->
          Logger.error("[fingerprint] could not open GPIO lines: #{inspect(error)}")
          {:stop, error}
      end
    end

    @impl GenServer
    def handle_call(:events, _from, state), do: {:reply, state.events, state}
    def handle_call(:irq, _from, state), do: {:reply, Circuits.GPIO.read(state.irq), state}

    def handle_call(:reset, _from, state) do
      pulse_reset(state.rst)
      {:reply, :ok, state}
    end

    @impl GenServer
    def handle_info({:circuits_gpio, _spec, ts, value}, state) do
      Logger.info("[fingerprint] irq -> #{value}")
      {:noreply, %{state | events: [{ts, value} | state.events]}}
    end

    @impl GenServer
    def terminate(_reason, state) do
      Circuits.GPIO.write(state.vdd, 0)
      Enum.each([state.irq, state.rst, state.vdd], &Circuits.GPIO.close/1)
      Logger.info("[fingerprint] sensor powered down")
    end

    # Same timing as the Android driver's elan_reset().
    defp pulse_reset(rst) do
      Circuits.GPIO.write(rst, 0)
      Process.sleep(5)
      Circuits.GPIO.write(rst, 1)
      Process.sleep(50)
    end
  end
end
