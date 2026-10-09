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
    # Plays nothing: reports :playing at once. The latest one's pid and
    # options are kept, so tests can speak for it and check how it started.

    def start(path, notify, _target, opts) do
      pid =
        spawn(fn ->
          send(notify, {:video, self(), :playing})
          loop(path, notify)
        end)

      :persistent_term.put(__MODULE__, {pid, opts})
      {:ok, pid}
    end

    def last, do: :persistent_term.get(__MODULE__)

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

  # Three shows sorted (two entertainment, one education), one video
  # that isn't, and a raw H.264 file. Watch history starts empty.
  setup do
    # The last test's controller may still be picking offers in a task.
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, {NervesPhone.State, @app})
    wait_for(fn -> Task.Supervisor.children(NervesPhone.TaskSupervisor) == [] end)

    root = hd(Application.fetch_env!(:nerves_phone, :videos)[:roots])
    File.rm_rf!(root)
    File.rm_rf!(Path.join(NervesPhone.state_dir(), "kids"))

    video(root, "paw/paw1.mp4", "Paw Patrol", "entertainment", "Pups save the day")
    video(root, "paw/paw2.mp4", "Paw Patrol", "entertainment", "Pups save the town")
    video(root, "bluey/bluey1.mp4", "Bluey", "entertainment", "Keepy Uppy")
    video(root, "numbers/one.mp4", "Numberblocks", "education", "One")
    File.cp!("test/fixtures/thumb.jpg", Path.join(root, "bluey/bluey1.jpg"))
    File.cp!("test/fixtures/tiny.mp4", Path.join(root, "unsorted.mp4"))
    File.mkdir_p!(Path.join(root, "clips"))
    File.write!(Path.join(root, "clips/clip.h264"), "x")

    Application.put_env(:nerves_phone, :video_player, FakePlayer)
    on_exit(fn -> Application.delete_env(:nerves_phone, :video_player) end)

    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, NervesPhone.Kids.History)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, NervesPhone.Kids.History)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, {NervesPhone.State, @app})

    {:ok, root: root}
  end

  defp video(root, name, series, kind, title) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.cp!("test/fixtures/tiny.mp4", path)

    meta = %{
      "title" => title,
      "series" => series,
      "kind" => kind,
      # Not the file's real length: long enough to stop partway.
      "duration" => 120,
      "thumbnail" => if(series == "Bluey", do: Path.basename(path, ".mp4") <> ".jpg")
    }

    File.write!(NervesPhone.Video.Metadata.path(path), JSON.encode!(meta))
  end

  test "offers the entertainment offering: one a show first, sorted videos only", %{
    root: root
  } do
    wait_for(fn -> not videos().loading end)

    offers = videos().offers
    assert videos().showing == "entertainment"
    assert length(offers) == 3
    assert Enum.all?(offers, &(&1.kind == "entertainment"))
    # Two shows for three slots: one has two.
    assert offers |> Enum.map(& &1.series) |> Enum.sort() == ["Bluey", "Paw Patrol", "Paw Patrol"]

    # Only offered videos play.
    Solve.dispatch(@app, :videos, :play, Path.join(root, "unsorted.mp4"))
    Process.sleep(100)
    assert videos().playback == nil
  end

  test "the offers stay the same until something's been watched" do
    wait_for(fn -> not videos().loading end)
    offers = videos().offers

    for _ <- 1..5 do
      Solve.dispatch(@app, :videos, :opened, nil)
      wait_for(fn -> not videos().loading end)
      assert videos().offers == offers
    end
  end

  test "playing, pausing and stopping" do
    wait_for(fn -> not videos().loading end)
    [offer | _] = videos().offers

    Solve.dispatch(@app, :videos, :play, offer.path)
    wait_for(fn -> match?(%{page: :player, playback: %{status: :playing}}, videos()) end)
    assert videos().playback.name == offer.title

    Solve.dispatch(@app, :videos, :toggle_pause, nil)
    wait_for(fn -> videos().playback.status == :paused end)
    Solve.dispatch(@app, :videos, :toggle_pause, nil)
    wait_for(fn -> videos().playback.status == :playing end)

    Solve.dispatch(@app, :videos, :stop, nil)
    wait_for(fn -> videos().page == :offers and videos().playback == nil end)
  end

  test "each video plays into a target of its own" do
    wait_for(fn -> not videos().loading end)
    [first, second | _] = videos().offers

    Solve.dispatch(@app, :videos, :play, first.path)
    wait_for(fn -> videos().playback != nil end)
    target = videos().playback.target

    Solve.dispatch(@app, :videos, :play, second.path)
    wait_for(fn -> videos().playback.name == second.title end)
    assert videos().playback.target != target
  end

  # Plays an offer, reporting positions as the player would, then stops it.
  defp watch(offer, positions) do
    Solve.dispatch(@app, :videos, :play, offer.path)

    wait_for(fn ->
      match?(%{status: :playing, name: name} when name == offer.title, videos().playback)
    end)

    {pipeline, _opts} = FakePlayer.last()
    controller = Solve.controller_pid(@app, :videos)
    for ms <- positions, do: send(controller, {:video, pipeline, {:position, ms}})
    wait_for(fn -> videos().playback.position_ms == List.last(positions) end)

    Solve.dispatch(@app, :videos, :stop, nil)
    wait_for(fn -> videos().page == :offers and not videos().loading end)
  end

  test "stopped partway, a video stays on offer; watched through, its slot gets a new one" do
    wait_for(fn -> not videos().loading end)
    offers = videos().offers
    bluey = Enum.find(offers, &(&1.series == "Bluey"))

    # 70 of 120 s, with a jump (a seek) that doesn't count.
    watch(bluey, Enum.to_list(0..40_000//250) ++ Enum.to_list(80_000..110_000//250))

    assert [%{path: path, series: "Bluey", kind: "entertainment", watched_s: 70}] =
             NervesPhone.Kids.History.all()

    assert path == bluey.path
    assert videos().offers == offers

    # A pipeline that isn't the current one is ignored.
    send(Solve.controller_pid(@app, :videos), {:video, self(), {:position, 5}})

    # 110 of 120 s: watched through. Its slot is refilled where it was, but
    # with nothing that fits (the only other show is on offer already, and
    # Bluey's just been watched) it stays empty.
    watch(bluey, Enum.to_list(0..110_000//250))
    at = Enum.find_index(offers, &(&1 == bluey))
    assert videos().offers == List.delete_at(offers, at)
  end

  test "after enough entertainment, the education offering; then entertainment as it was" do
    {:ok, _} = NervesPhone.Kids.Rules.put(entertainment_limit_min: 1, education_required_min: 1)
    wait_for(fn -> not videos().loading end)
    fun = videos().offers
    [paw | _] = Enum.filter(fun, &(&1.series == "Paw Patrol"))

    watch(paw, Enum.to_list(0..61_000//250))
    assert videos().showing == "education"
    assert [%{series: "Numberblocks"} = one] = videos().offers

    watch(one, Enum.to_list(0..61_000//250))
    assert videos().showing == "entertainment"
    assert videos().offers == fun
  end

  test "an MP4 is indexed, and seeking plays from the new time" do
    wait_for(fn -> not videos().loading end)
    paw = Enum.find(videos().offers, &(&1.series == "Paw Patrol"))
    Solve.dispatch(@app, :videos, :play, paw.path)
    wait_for(fn -> match?(%{status: :playing, duration_ms: 2_000}, videos().playback) end)
    {first, opts} = FakePlayer.last()
    assert opts[:start_ms] == 0 and opts[:index].video.count == 60

    # Dragging: the time follows at once, the seek waits for a pause.
    for ms <- [400, 800, 1_200], do: Solve.dispatch(@app, :videos, :seek, ms)
    wait_for(fn -> videos().playback.position_ms == 1_200 end)
    assert {^first, _} = FakePlayer.last()

    wait_for(fn -> elem(FakePlayer.last(), 0) != first end)
    assert {_pipeline, [index: _, start_ms: 1_200]} = FakePlayer.last()
    wait_for(fn -> videos().playback.status == :playing end)
  end

  test "renders the offers and the player" do
    viewport =
      start_supervised!(
        {NervesPhone.UI,
         backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
      )

    assert_receive {:emerge_skia_frame, _frame}, 5_000
    snapshot(viewport, "videos-0-home")

    Solve.dispatch(@app, :shell, :open, Videos)
    wait_for(fn -> not videos().loading end)
    snapshot(viewport, "videos-1-offers")

    [offer | _] = videos().offers
    Solve.dispatch(@app, :videos, :play, offer.path)
    wait_for(fn -> videos().page == :player end)
    snapshot(viewport, "videos-2-player")

    Solve.dispatch(@app, :device, :volume_changed, 12)
    snapshot(viewport, "videos-2-player-volume")

    Solve.dispatch(@app, :videos, :stop, nil)
    wait_for(fn -> videos().page == :offers end)

    # Only education, as after too much entertainment.
    history = NervesPhone.Kids.History

    for _ <- 1..2 do
      entry = history.start(%{path: offer.path, series: "Bluey", kind: "entertainment"})
      history.watched(entry.id, 31 * 60)
    end

    {:ok, _} = NervesPhone.Kids.Rules.reset()
    Solve.dispatch(@app, :videos, :opened, nil)
    wait_for(fn -> videos().showing == "education" end)
    snapshot(viewport, "videos-3-learning")
  end

  describe "MP4 index and source" do
    alias NervesPhone.Video.{MP4, MP4Source}

    setup do
      Application.put_env(:nerves_phone, :state_dir, NervesPhone.state_dir())
      {:ok, index} = MP4.index("test/fixtures/tiny.mp4")
      {:ok, index: index}
    end

    test "lists every sample, with keyframes", %{index: index} do
      assert index.duration_ns == 2_000_000_000
      assert index.video.count == 60
      assert Tuple.to_list(index.video.keyframes) == [0, 15, 30, 45]
      assert %Membrane.H264{width: 160, height: 90} = index.video.format
      assert %Membrane.AAC{} = index.audio.format
      assert MP4.start_sample(index.video, :video, 1_100_000_000) == 30
    end

    test "reads from the keyframe before the start, both tracks to the end", %{index: index} do
      import Membrane.ChildrenSpec
      require Membrane.Pad

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, %MP4Source{
              path: "test/fixtures/tiny.mp4",
              index: index,
              start_ns: 1_100_000_000
            }),
            get_child(:source)
            |> via_out(Membrane.Pad.ref(:output, :video))
            |> child(:video, Testing.Sink),
            get_child(:source)
            |> via_out(Membrane.Pad.ref(:output, :audio))
            |> child(:audio, Testing.Sink)
          ]
        )

      assert_sink_stream_format(pipeline, :video, %Membrane.H264{})
      assert_sink_buffer(pipeline, :video, %Membrane.Buffer{pts: pts})
      {_offset, _size, _dts, keyframe_pts, true} = MP4.sample(index.video, 30)
      assert pts == keyframe_pts
      assert_sink_buffer(pipeline, :audio, %Membrane.Buffer{pts: audio_pts})
      assert audio_pts >= 1_100_000_000
      assert_end_of_stream(pipeline, :video)
      assert_end_of_stream(pipeline, :audio)
    end
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
