defmodule NervesPhone.PlayerTest do
  # Runs the Solve app against NervesPhone.Music.FakeBackend and renders the
  # UI headless with the CPU raster renderer (see config/host.exs). Set
  # UI_SNAPSHOT_DIR to also save each screen as a PNG.
  use ExUnit.Case

  alias NervesPhone.Music.FakeBackend

  @app NervesPhone.State

  setup do
    FakeBackend.set(calls: [], shuffle: true, smart_shuffle: false, playing: true)

    # Fresh state for each test.
    id = {NervesPhone.State, @app}
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, id)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, id)

    wait_for(fn -> Solve.subscribe(@app, :library).status == :ready end)
    wait_for(fn -> Solve.subscribe(@app, :player).device_ready end)
    :ok
  end

  test "the library lists every playlist" do
    library = Solve.subscribe(@app, :library)
    assert length(library.visible) == 40

    Solve.dispatch(@app, :library, :set_filter, :mine)
    wait_for(fn -> length(Solve.subscribe(@app, :library).visible) < 40 end)
  end

  test "opening a playlist loads all its tracks, page by page" do
    Solve.dispatch(@app, :workspace, :open_playlist, "p2")
    wait_for(fn -> match?(%{status: :ready}, Solve.subscribe(@app, :workspace).context) end)

    workspace = Solve.subscribe(@app, :workspace)
    assert workspace.active == {:playlist, "p2"}
    assert length(workspace.context.tracks) == 120
    assert [%{key: {:playlist, "p2"}}] = workspace.open
  end

  test "a playlist the service won't list can still be played" do
    Solve.dispatch(@app, :workspace, :open_playlist, "p3")

    wait_for(fn ->
      match?(%{status: :not_listable}, Solve.subscribe(@app, :workspace).context)
    end)
  end

  test "shuffle play starts at a random track; a tapped track plays from there" do
    Solve.dispatch(@app, :player, :play_context, %{uri: "fake:playlist:p2", total: 120})
    wait_for(fn -> Enum.any?(FakeBackend.calls(), &match?({:play, _, _}, &1)) end)
    assert [{:play, "fake:playlist:p2", {:random, 120}}] = FakeBackend.calls()

    FakeBackend.set(calls: [])

    Solve.dispatch(@app, :player, :play_track, %{
      context_uri: "fake:album:a1",
      track_uri: "fake:track:x"
    })

    wait_for(fn ->
      FakeBackend.calls() == [{:play, "fake:album:a1", {:track, "fake:track:x"}}]
    end)
  end

  test "shuffle is turned back on if something turns it off or makes it smart" do
    FakeBackend.set(smart_shuffle: true)
    wait_for(fn -> :ensure_shuffle in FakeBackend.calls() end, 5_000)

    FakeBackend.set(calls: [], smart_shuffle: false, shuffle: false)
    wait_for(fn -> :ensure_shuffle in FakeBackend.calls() end, 5_000)
  end

  test "play/pause, previous and next" do
    Solve.dispatch(@app, :player, :toggle_play, nil)
    wait_for(fn -> :pause in FakeBackend.calls() end)
    refute Solve.subscribe(@app, :player).is_playing

    Solve.dispatch(@app, :player, :toggle_play, nil)
    wait_for(fn -> :resume in FakeBackend.calls() end)
    assert Solve.subscribe(@app, :player).is_playing

    Solve.dispatch(@app, :player, :next, nil)
    Solve.dispatch(@app, :player, :previous, nil)
    wait_for(fn -> :next in FakeBackend.calls() and :previous in FakeBackend.calls() end)
  end

  test "the volume buttons step the volume and stop at the ends" do
    NervesPhone.Audio.Volume.set(15)
    Solve.dispatch(@app, :player, :volume_up, nil)
    Solve.dispatch(@app, :player, :volume_up, nil)
    wait_for(fn -> Solve.subscribe(@app, :player).volume == 16 end)

    Solve.dispatch(@app, :player, :volume_down, nil)
    wait_for(fn -> Solve.subscribe(@app, :player).volume == 15 end)
  end

  test "search waits for typing to pause and keeps only the latest results" do
    Solve.dispatch(@app, :workspace, :show, :search)
    Solve.dispatch(@app, :workspace, :query_changed, "bea")
    Solve.dispatch(@app, :workspace, :query_changed, "beatles")
    wait_for(fn -> Solve.subscribe(@app, :workspace).search.status == :ready end)

    %{search: search} = Solve.subscribe(@app, :workspace)
    assert [%{name: "beatles (Radio Edit)"}] = search.results.tracks

    Solve.dispatch(@app, :workspace, :open_album, hd(search.results.albums))

    wait_for(fn ->
      match?(%{kind: :album, status: :ready}, Solve.subscribe(@app, :workspace).context)
    end)
  end

  test "closing an open playlist goes back to the library" do
    Solve.dispatch(@app, :workspace, :open_playlist, "p1")
    Solve.dispatch(@app, :workspace, :close, {:playlist, "p1"})
    wait_for(fn -> Solve.subscribe(@app, :workspace).open == [] end)
    assert Solve.subscribe(@app, :workspace).active == :library
  end

  test "the screen goes dark without touches and a touch wakes it" do
    Application.put_env(:nerves_phone, :screen_timeout_ms, 200)
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, NervesPhone.Screen)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, NervesPhone.Screen)

    wait_for(fn -> not Solve.subscribe(@app, :device).screen_on end, 3_000)

    NervesPhone.Screen.touch()
    wait_for(fn -> Solve.subscribe(@app, :device).screen_on end)
  after
    Application.delete_env(:nerves_phone, :screen_timeout_ms)
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, NervesPhone.Screen)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, NervesPhone.Screen)
  end

  test "renders every screen" do
    viewport =
      start_supervised!(
        {NervesPhone.UI,
         backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
      )

    assert_receive {:emerge_skia_frame, _frame}, 5_000
    wait_for(fn -> Solve.subscribe(@app, :player).track end)
    snapshot(viewport, "1-library")

    Solve.dispatch(@app, :workspace, :open_playlist, "p2")
    wait_for(fn -> match?(%{status: :ready}, Solve.subscribe(@app, :workspace).context) end)
    snapshot(viewport, "2-playlist")

    Solve.dispatch(@app, :workspace, :show, :search)
    Solve.dispatch(@app, :workspace, :query_changed, "abba")
    wait_for(fn -> Solve.subscribe(@app, :workspace).search.status == :ready end)
    snapshot(viewport, "3-search")

    Solve.dispatch(@app, :workspace, :show, :now_playing)
    snapshot(viewport, "4-playing")
  end

  defp snapshot(viewport, name) do
    # Let the update reach the viewport and the next frame render.
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
