defmodule NervesPhone.VolumeOverlayTest do
  # The volume overlay: shown for a moment when the volume buttons change
  # the volume. Set UI_SNAPSHOT_DIR to save the screens as PNGs.
  use ExUnit.Case

  @app NervesPhone.State

  setup do
    id = {NervesPhone.State, @app}
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, id)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, id)
    :ok
  end

  test "a volume change shows the overlay, which goes away after the last one" do
    refute device().volume_overlay

    Solve.dispatch(@app, :device, :volume_changed, 7)
    wait_for(fn -> device().volume_overlay and device().volume == 7 end)

    # Another press keeps it up.
    Process.sleep(1_000)
    Solve.dispatch(@app, :device, :volume_changed, 8)
    Process.sleep(1_000)
    assert device().volume_overlay

    wait_for(fn -> not device().volume_overlay end, 1_500)
  end

  test "renders over the home screen and a full-screen app" do
    viewport =
      start_supervised!(
        {NervesPhone.UI,
         backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
      )

    assert_receive {:emerge_skia_frame, _frame}, 5_000
    Solve.dispatch(@app, :device, :volume_changed, 10)
    wait_for(fn -> device().volume_overlay end)
    snapshot(viewport, "volume-home")
  end

  defp device, do: Solve.subscribe(@app, :device)

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
