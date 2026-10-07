defmodule NervesPhone.Audio.Pipeline do
  @moduledoc """
  Plays librespot's PCM on the local sound card:

      FifoSource (librespot's FIFO) -> PortAudio.Sink (default output)

  On the phone PortAudio uses ALSA's default device, which
  `rootfs_overlay/etc/asound.conf` routes through a software volume control
  (see `NervesPhone.Audio.Volume`). `ex_audio`'s mixer settings in
  `config/fp3.exs` route it to the loudspeaker.
  """

  use Membrane.Pipeline

  def start_link(opts \\ []), do: Membrane.Pipeline.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def handle_init(_ctx, opts) do
    fifo = Keyword.get(opts, :fifo, NervesPhone.Music.Backend.impl().audio_fifo())

    # A small input queue (~0.1 s) keeps the audio close behind librespot,
    # so skip takes effect quickly.
    spec =
      child(:source, %NervesPhone.Audio.FifoSource{path: fifo})
      |> via_in(:input, target_queue_size: 16_384)
      |> child(:sink, %Membrane.PortAudio.Sink{latency: :high})

    {[spec: spec], %{}}
  end
end
