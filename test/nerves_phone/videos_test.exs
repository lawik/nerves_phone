defmodule NervesPhone.VideosTest do
  # The Videos app against a fake player (there's no hardware decoder on the
  # host), and the pacing elements in Membrane test pipelines. Set
  # UI_SNAPSHOT_DIR to save the screens as PNGs.
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing
  alias NervesPhone.Apps.Videos
  alias NervesPhone.Video.{AudioGate, Pacer}

  @app NervesPhone.State

  defmodule FakePlayer do
    @moduledoc false
    # Plays nothing: reports :playing at once, and remembers what it's told.

    def start(path, notify, _target) do
      pid =
        spawn(fn ->
          send(notify, {:video, :playing})
          loop(path, notify)
        end)

      {:ok, pid}
    end

    def pause(pid), do: send(pid, :pause)
    def resume(pid), do: send(pid, :resume)
    def stop(pid), do: send(pid, :stop)

    defp loop(path, notify) do
      receive do
        :stop -> :ok
        _other -> loop(path, notify)
      end
    end
  end

  setup do
    root = hd(Application.fetch_env!(:nerves_phone, :videos)[:roots])
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "holiday"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    File.write!(Path.join(root, "holiday/beach.mp4"), String.duplicate("x", 2_000_000))
    File.write!(Path.join(root, "holiday/Arrival.MOV"), "x")
    File.write!(Path.join(root, "clip.h264"), "x")
    File.write!(Path.join(root, "notes.txt"), "x")
    File.write!(Path.join(root, ".hidden/secret.mp4"), "x")

    Application.put_env(:nerves_phone, :video_player, FakePlayer)
    on_exit(fn -> Application.delete_env(:nerves_phone, :video_player) end)

    id = {NervesPhone.State, @app}
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, id)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, id)
    {:ok, root: root}
  end

  test "the library lists video files by folder, skipping hidden ones", %{root: root} do
    wait_for(fn -> not videos().scanning end)

    assert [{^root, [%{name: "clip.h264"}]}, {"holiday", holiday}] = videos().folders
    assert Enum.map(holiday, & &1.name) == ["Arrival.MOV", "beach.mp4"]
  end

  test "playing, pausing and stopping", %{root: root} do
    wait_for(fn -> not videos().scanning end)
    path = Path.join(root, "holiday/beach.mp4")

    Solve.dispatch(@app, :videos, :play, path)
    wait_for(fn -> match?(%{page: :player, playback: %{status: :playing}}, videos()) end)
    assert videos().playback.name == "beach.mp4"

    Solve.dispatch(@app, :videos, :toggle_pause, nil)
    wait_for(fn -> videos().playback.status == :paused end)
    Solve.dispatch(@app, :videos, :toggle_pause, nil)
    wait_for(fn -> videos().playback.status == :playing end)

    Solve.dispatch(@app, :videos, :stop, nil)
    wait_for(fn -> videos().page == :library and videos().playback == nil end)
  end

  test "each video plays into a target of its own", %{root: root} do
    wait_for(fn -> not videos().scanning end)

    Solve.dispatch(@app, :videos, :play, Path.join(root, "holiday/beach.mp4"))
    wait_for(fn -> videos().playback != nil end)
    first = videos().playback.target

    Solve.dispatch(@app, :videos, :play, Path.join(root, "clip.h264"))
    wait_for(fn -> videos().playback.name == "clip.h264" end)
    assert videos().playback.target != first
  end

  test "the player's end and errors show on the player page", %{root: root} do
    wait_for(fn -> not videos().scanning end)
    Solve.dispatch(@app, :videos, :play, Path.join(root, "clip.h264"))
    wait_for(fn -> videos().playback != nil end)

    send(Solve.controller_pid(@app, :videos), {:video, {:position, 61_000}})
    send(Solve.controller_pid(@app, :videos), {:video, :ended})
    wait_for(fn -> match?(%{status: :ended, position_ms: 61_000}, videos().playback) end)
  end

  test "renders the library and the player", %{root: root} do
    viewport =
      start_supervised!(
        {NervesPhone.UI,
         backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
      )

    assert_receive {:emerge_skia_frame, _frame}, 5_000
    snapshot(viewport, "videos-0-home")

    Solve.dispatch(@app, :shell, :open, Videos)
    wait_for(fn -> not videos().scanning end)
    snapshot(viewport, "videos-1-library")

    Solve.dispatch(@app, :videos, :play, Path.join(root, "holiday/beach.mp4"))
    wait_for(fn -> videos().page == :player end)
    snapshot(viewport, "videos-2-player")

    # The real player can't stop the fake one's process, so the new video
    # starts when the handover gives up waiting (3 s).
    Application.delete_env(:nerves_phone, :video_player)
    Solve.dispatch(@app, :videos, :play, Path.join(root, "clip.h264"))
    wait_for(fn -> match?(%{status: {:error, _}}, videos().playback) end, 5_000)
    snapshot(viewport, "videos-3-error")
  end

  describe "Pacer" do
    test "waits to be started, then lets frames through at their pts" do
      buffers =
        for n <- 0..4, do: %Membrane.Buffer{pts: Membrane.Time.milliseconds(n * 40), payload: n}

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, %Testing.Source{output: buffers})
            |> child(:pacer, Pacer)
            |> child(:sink, Testing.Sink)
        )

      assert_pipeline_notified(pipeline, :pacer, {:ready, 0})
      refute_sink_buffer(pipeline, :sink, _, 100)

      started = System.monotonic_time(:millisecond)
      Testing.Pipeline.notify_child(pipeline, :pacer, {:start, started + 50, 0})

      for n <- 0..4 do
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^n}, 1_000)
        late = System.monotonic_time(:millisecond) - (started + 50 + n * 40)
        assert late >= 0 and late < 40, "frame #{n} came #{late} ms after its time"
      end

      assert_end_of_stream(pipeline, :sink)
    end

    test "pauses and resumes, and drops frames that are already late" do
      buffers =
        for n <- 0..9, do: %Membrane.Buffer{pts: Membrane.Time.milliseconds(n * 40), payload: n}

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, %Testing.Source{output: buffers})
            |> child(:pacer, Pacer)
            |> child(:sink, Testing.Sink)
        )

      assert_pipeline_notified(pipeline, :pacer, {:ready, 0})
      Process.sleep(50)

      # Started 130 ms in the past: frames 0-3 are due, only 3 goes out.
      Testing.Pipeline.notify_child(
        pipeline,
        :pacer,
        {:start, System.monotonic_time(:millisecond) - 130, 0}
      )

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: 3})
      Testing.Pipeline.notify_child(pipeline, :pacer, :pause)
      refute_sink_buffer(pipeline, :sink, _, 200)

      Testing.Pipeline.notify_child(pipeline, :pacer, :resume)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: 4}, 500)
    end
  end

  describe "AudioGate" do
    test "holds audio until opened, and while paused" do
      buffers =
        for n <- 0..2, do: %Membrane.Buffer{pts: Membrane.Time.milliseconds(n * 20), payload: n}

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, %Testing.Source{output: buffers})
            |> child(:gate, AudioGate)
            |> child(:sink, Testing.Sink)
        )

      assert_pipeline_notified(pipeline, :gate, {:ready, 0})
      refute_sink_buffer(pipeline, :sink, _, 100)

      Testing.Pipeline.notify_child(pipeline, :gate, :open)
      for n <- 0..2, do: assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^n})
      assert_end_of_stream(pipeline, :sink)
    end
  end

  defp videos, do: Solve.subscribe(@app, :videos)

  defp snapshot(viewport, name) do
    Process.sleep(300)
    {:ok, png} = EmergeSkia.render_to_png(Emerge.renderer(viewport), timeout: 5_000)
    assert <<0x89, "PNG", _::binary>> = png

    if dir = System.get_env("UI_SNAPSHOT_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name <> ".png"), png)
    end
  end

  defp wait_for(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(20) && false) end)
    |> Enum.find(fn result -> result || System.monotonic_time(:millisecond) > deadline end)
    |> case do
      false -> flunk("condition not met within #{timeout} ms")
      _ -> :ok
    end
  end
end
