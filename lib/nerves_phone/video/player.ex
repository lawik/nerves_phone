defmodule NervesPhone.Video.Player do
  @moduledoc """
  Plays a video file: the picture into one of the UI's video targets, the
  sound to the speaker.

      File.Source -> [MP4 demuxer] -+-> H264.Parser -> Membrane.V4L2.H264.Decoder
                                    |     -> Pacer -> Membrane.VideoInterop.Sink -> Emerge
                                    +-> AAC.Parser -> AAC.FDK.Decoder
                                          -> AudioGate -> PortAudio.Sink -> ALSA

  The video decoder is the phone's Venus hardware decoder; frames reach the
  screen as DMA-BUFs without being copied (see membrane_v4l2_decoder).
  MP4 and QuickTime files are demuxed, with or without "fast start"; the
  first AAC track plays, and any other tracks are dropped. Raw H.264
  (`.h264`, `.264`) has no timestamps or sound, so it plays at 30 fps.

  ## Keeping picture and sound together

  The first video frame takes longer to decode than the first audio, so
  both are held until both are ready: the `Pacer` reports the first frame's
  pts, the `AudioGate` the first sound's. Then the pipeline picks a start
  time and the earliest pts as the common origin, opens the gate when the
  sound's pts comes round, and starts the pacer so the picture shows each
  frame's pts that long after the start, plus the sound card's output
  latency. Without a sound track, the picture starts straight away.

  The picture then follows the system clock and the sound the sound card's.
  They drift apart by the difference between the two clocks (some tens of
  parts per million: a frame in ten minutes or so).

  ## Messages

  The pipeline tells `notify` `{:video, message}`: `:playing` once the
  first frame is shown, `{:position, ms}`, `:ended`, and `{:error, reason}`.

  Before stopping, take the video element off screen so Emerge lets go of
  the frame it shows; the decoder waits for every frame to come back when
  it shuts down.
  """

  @extensions ~w(.mp4 .m4v .mov .h264 .264)

  @doc "File extensions the player handles."
  def extensions, do: @extensions

  @doc """
  Starts playing `path` into the UI's video target `target`, reporting to
  `notify`. Use a fresh target for each video: Emerge keeps showing the
  last frame a target got, so reusing one would show the previous video
  until the new one's first frame.
  """
  @spec start(Path.t(), pid(), atom()) :: {:ok, pid()} | {:error, term()}
  if Mix.target() == :host do
    def start(_path, _notify, _target), do: {:error, :no_hardware_decoder}
  else
    def start(path, notify, target) do
      with {:ok, _supervisor, pipeline} <-
             Membrane.Pipeline.start(__MODULE__.Pipeline, %{
               path: path,
               notify: notify,
               target: target
             }) do
        {:ok, pipeline}
      end
    end
  end

  def pause(pipeline), do: send(pipeline, :pause)
  def resume(pipeline), do: send(pipeline, :resume)

  @doc "Stops the pipeline without waiting for it."
  def stop(pipeline) do
    Membrane.Pipeline.terminate(pipeline, asynchronous?: true)
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Membrane.VideoInterop.Sink's callback: hands each frame to the UI.
  def submit(frame, target) do
    case Process.whereis(NervesPhone.UI) do
      nil ->
        VideoInterop.release(frame)
        {:error, :no_viewport}

      viewport ->
        Emerge.submit_video_frame(viewport, target, frame)
    end
  end

  if Mix.target() != :host do
    defmodule Pipeline do
      @moduledoc false
      use Membrane.Pipeline

      require Membrane.Logger

      # Time to get everything moving between deciding to start and the
      # first frame being due.
      @start_margin_ms 60
      # How long the picture waits for sound before starting without it.
      @audio_wait_ms 1_500
      # File reads. Until it has the whole index (`moov`, megabytes for a
      # long video), the MP4 demuxer parses everything it has received again
      # on each chunk, so small chunks make opening a file very slow.
      @chunk_size 1_048_576
      # Sound queued at the sink: 2048 frames, ~46 ms at 44.1 kHz stereo.
      @audio_queue_bytes 8_192
      # How long sound keeps coming after the gate closes: that queue, the
      # sink's 2048-frame ring buffer and the device's 10 ms latency. The
      # picture pauses this much later, so both stop at the same point.
      @audio_tail_ms 80

      @impl true
      def handle_init(_ctx, %{path: path, notify: notify, target: target}) do
        state = %{
          notify: notify,
          target: target,
          audio?: false,
          video_first: nil,
          audio_first: nil,
          started?: false,
          paused?: false,
          pause_timer: nil
        }

        if String.downcase(Path.extname(path)) in ~w(.h264 .264) do
          spec =
            child(:source, %Membrane.File.Source{location: path, chunk_size: @chunk_size})
            |> child(:parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {30, 1}},
              output_alignment: :au,
              output_stream_structure: :annexb
            })
            |> video_tail(state.target)

          {[spec: spec], state}
        else
          spec =
            child(:source, %Membrane.File.Source{
              location: path,
              seekable?: true,
              chunk_size: @chunk_size
            })
            |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})

          {[spec: spec], state}
        end
      end

      @impl true
      def handle_child_notification({:new_tracks, tracks}, :demuxer, _ctx, state) do
        video = Enum.find(tracks, fn {_id, format} -> match?(%Membrane.H264{}, format) end)
        audio = Enum.find(tracks, fn {_id, format} -> match?(%Membrane.AAC{}, format) end)

        case video do
          nil ->
            report(state, {:error, :no_h264_video})
            {[], state}

          {video_id, _format} ->
            video_branch =
              get_child(:demuxer)
              |> via_out(Membrane.Pad.ref(:output, video_id))
              |> child(:parser, %Membrane.H264.Parser{
                output_alignment: :au,
                output_stream_structure: :annexb
              })
              |> video_tail(state.target)

            audio_branch =
              case audio do
                {audio_id, _format} ->
                  [
                    get_child(:demuxer)
                    |> via_out(Membrane.Pad.ref(:output, audio_id))
                    |> child(:aac_parser, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
                    |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
                    |> child(:audio_gate, NervesPhone.Video.AudioGate)
                    # Membrane's default input queue here holds ~0.85 s of
                    # sound past the gate, which would play on after a pause.
                    |> via_in(:input, target_queue_size: @audio_queue_bytes)
                    |> child(:audio_sink, %Membrane.PortAudio.Sink{
                      latency: :low,
                      ringbuffer_size: 2048
                    })
                  ]

                nil ->
                  []
              end

            # The demuxer wants every track linked.
            playing = for {id, _} <- [video, audio], id != nil, do: id

            others =
              for {id, _format} <- tracks, id not in playing do
                get_child(:demuxer)
                |> via_out(Membrane.Pad.ref(:output, id))
                |> child({:discard, id}, Membrane.Fake.Sink)
              end

            {[spec: [video_branch | audio_branch ++ others]], %{state | audio?: audio != nil}}
        end
      end

      def handle_child_notification({:ready, pts}, :pacer, _ctx, state) do
        if state.audio?, do: Process.send_after(self(), :stop_waiting_for_audio, @audio_wait_ms)
        maybe_start(%{state | video_first: pts})
      end

      def handle_child_notification({:ready, pts}, :audio_gate, _ctx, state),
        do: maybe_start(%{state | audio_first: pts})

      def handle_child_notification(:first_frame, :pacer, _ctx, state) do
        report(state, :playing)
        {[], state}
      end

      def handle_child_notification({:position, ms}, :pacer, _ctx, state) do
        report(state, {:position, ms})
        {[], state}
      end

      def handle_child_notification({:video_interop_sink_error, reason}, :sink, _ctx, state) do
        Membrane.Logger.warning("video frame not shown: #{inspect(reason)}")
        {[], state}
      end

      def handle_child_notification(_message, _child, _ctx, state), do: {[], state}

      @impl true
      def handle_element_end_of_stream(:sink, :input, _ctx, state) do
        report(state, :ended)
        {[], state}
      end

      def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}

      @impl true
      def handle_info(:stop_waiting_for_audio, _ctx, %{started?: false} = state) do
        Membrane.Logger.warning("no sound after #{@audio_wait_ms} ms; starting the picture")
        start(%{state | audio?: false}, nil)
      end

      def handle_info(:open_gate, _ctx, state) do
        # ALSA's volume control only exists once sound has played.
        Process.send_after(self(), :reapply_volume, 500)
        {[notify_child: {:audio_gate, :open}], state}
      end

      def handle_info(:reapply_volume, _ctx, state) do
        NervesPhone.Audio.Volume.reapply()
        {[], state}
      end

      # The sound stops at the gate at once, but what's past it still plays
      # for @audio_tail_ms, so the picture pauses that much later. On resume
      # the sound card's buffers are empty, so both go on together.
      def handle_info(:pause, _ctx, %{started?: true, paused?: false, audio?: true} = state) do
        timer = Process.send_after(self(), :pause_picture, @audio_tail_ms)
        {[notify_child: {:audio_gate, :pause}], %{state | paused?: true, pause_timer: timer}}
      end

      def handle_info(:pause, _ctx, %{started?: true, paused?: false} = state),
        do: {[notify_child: {:pacer, :pause}], %{state | paused?: true}}

      def handle_info(:pause_picture, _ctx, %{paused?: true} = state),
        do: {[notify_child: {:pacer, :pause}], %{state | pause_timer: nil}}

      def handle_info(:resume, _ctx, %{paused?: true} = state) do
        # Resumed before the picture caught up with the sound: it never paused.
        picture =
          if state.pause_timer && Process.cancel_timer(state.pause_timer),
            do: [],
            else: [notify_child: {:pacer, :resume}]

        {picture ++ audio_notify(state, :resume), %{state | paused?: false, pause_timer: nil}}
      end

      def handle_info(_message, _ctx, state), do: {[], state}

      defp maybe_start(%{started?: true} = state), do: {[], state}
      defp maybe_start(%{video_first: nil} = state), do: {[], state}
      defp maybe_start(%{audio?: true, audio_first: nil} = state), do: {[], state}
      defp maybe_start(state), do: start(state, state.audio_first)

      # pts `origin` (the earliest first pts) is due at `t0`. The sound
      # starts when its first pts is due; the picture is shown later by the
      # sound card's output latency, so the two are heard and seen together.
      defp start(state, audio_first) do
        origin = Enum.min([state.video_first | List.wrap(audio_first)])
        t0 = System.monotonic_time(:millisecond) + @start_margin_ms
        latency = if audio_first, do: audio_latency_ms(), else: 0

        if audio_first do
          delay = @start_margin_ms + Membrane.Time.as_milliseconds(audio_first - origin, :round)
          Process.send_after(self(), :open_gate, max(delay, 0))
        end

        {[notify_child: {:pacer, {:start, t0 + latency, origin}}],
         %{state | started?: true, audio?: audio_first != nil}}
      end

      # The sound card's output latency, by which the picture is held back.
      # PortAudio.Sink measures it but doesn't expose it: 10 ms on the FP3 with
      # `latency: :low`, plus the 256-frame PortAudio buffer.
      defp audio_latency_ms, do: Application.get_env(:nerves_phone, :audio_latency_ms, 15)

      defp audio_notify(%{audio?: true}, message), do: [notify_child: {:audio_gate, message}]
      defp audio_notify(_state, _message), do: []

      defp video_tail(builder, target) do
        builder
        |> child(:decoder, Membrane.V4L2.H264.Decoder)
        |> child(:pacer, NervesPhone.Video.Pacer)
        |> child(:sink, %Membrane.VideoInterop.Sink{
          submit: {NervesPhone.Video.Player, :submit, []},
          target: target
        })
      end

      defp report(state, message), do: send(state.notify, {:video, message})
    end
  end
end
