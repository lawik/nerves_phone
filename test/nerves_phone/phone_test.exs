defmodule NervesPhone.PhoneTest do
  # Runs the Solve app against NervesPhone.Net's host stand-in and renders
  # the UI headless with the CPU raster renderer (see config/host.exs). Set
  # UI_SNAPSHOT_DIR to also save each screen as a PNG.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias NervesPhone.Apps.Settings

  @app NervesPhone.State

  setup do
    NervesPhone.Net.reset()

    # Fresh state for each test.
    id = {NervesPhone.State, @app}
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, id)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, id)
    :ok
  end

  test "apps open from home, and Home goes back" do
    assert Solve.subscribe(@app, :shell).active == nil

    Solve.dispatch(@app, :shell, :open, Settings)
    wait_for(fn -> Solve.subscribe(@app, :shell).active == Settings end)

    Solve.dispatch(@app, :shell, :open, NotAnApp)
    Solve.dispatch(@app, :shell, :home, nil)
    wait_for(fn -> Solve.subscribe(@app, :shell).active == nil end)
  end

  test "the schedule hides apps, and closes the one open when its time's up" do
    Solve.dispatch(@app, :shell, :open, Settings)
    wait_for(fn -> Solve.subscribe(@app, :shell).active == Settings end)

    # Settings, never; Videos and Flash Cards, always (they aren't
    # scheduled).
    closed = %{"timezone" => "Etc/UTC", "apps" => %{"NervesPhone.Apps.Settings" => []}}
    Solve.dispatch(@app, :schedule, :changed, closed)

    wait_for(fn ->
      shell = Solve.subscribe(@app, :shell)

      shell.active == nil and
        shell.available == [NervesPhone.Apps.Videos, NervesPhone.Apps.Flashcards]
    end)

    Solve.dispatch(@app, :shell, :open, Settings)
    Solve.dispatch(@app, :shell, :open, NervesPhone.Apps.Videos)
    wait_for(fn -> Solve.subscribe(@app, :shell).active == NervesPhone.Apps.Videos end)

    Solve.dispatch(@app, :schedule, :changed, NervesPhone.Schedule.empty())
    wait_for(fn -> Settings in Solve.subscribe(@app, :shell).available end)
  end

  test "Wi-Fi lists the networks around, one entry each, strongest first" do
    settings = Solve.subscribe(@app, :settings)
    assert settings.wifi.current.ssid == "Workshop"

    assert Enum.map(settings.access_points, & &1.ssid) ==
             ["Workshop", "Café Guest", "Office", "Neighbours"]
  end

  test "Wi-Fi turns off and on" do
    Solve.dispatch(@app, :settings, :toggle_wifi, nil)
    wait_for(fn -> not settings().wifi.enabled and settings().access_points == [] end)
    wait_for(fn -> Solve.subscribe(@app, :device).network.kind == :usb end, 6_000)

    Solve.dispatch(@app, :settings, :toggle_wifi, nil)
    wait_for(fn -> settings().wifi.enabled and settings().access_points != [] end, 3_000)
  end

  test "a protected network asks for its password, typed on the keyboard" do
    neighbours = Enum.find(settings().access_points, &(&1.ssid == "Neighbours"))
    Solve.dispatch(@app, :settings, :pick, neighbours)
    wait_for(fn -> settings().page == :join end)

    for char <- ~w(s e c r e t) do
      Solve.dispatch(@app, :settings, :key, {:text, char})
    end

    Solve.dispatch(@app, :settings, :key, :action)
    wait_for(fn -> settings().join.error =~ "at least 8" end)

    Solve.dispatch(@app, :settings, :key, {:layer, :upper})
    Solve.dispatch(@app, :settings, :key, {:text, "X"})
    Solve.dispatch(@app, :settings, :key, {:text, "y"})
    Solve.dispatch(@app, :settings, :key, :backspace)
    Solve.dispatch(@app, :settings, :key, {:text, "z"})
    wait_for(fn -> settings().join.password == "secretXz" and settings().join.layer == :lower end)

    Solve.dispatch(@app, :settings, :join, nil)
    wait_for(fn -> settings().page == :wifi end)
    wait_for(fn -> match?(%{ssid: "Neighbours"}, settings().wifi.current) end, 3_000)
  end

  test "an open network is joined at once, and can be forgotten" do
    cafe = Enum.find(settings().access_points, &(&1.ssid == "Café Guest"))
    Solve.dispatch(@app, :settings, :pick, cafe)
    wait_for(fn -> match?(%{ssid: "Café Guest"}, settings().wifi.current) end, 3_000)

    Solve.dispatch(@app, :settings, :forget, nil)
    wait_for(fn -> settings().wifi.ssid == nil end, 3_000)
  end

  describe "the screen" do
    setup do
      on_exit(fn ->
        Fp3Extras.Screen.put_settings(
          brightness: 60,
          auto: false,
          dim_after_ms: nil,
          off_after_ms: nil
        )

        Application.delete_env(:fp3_extras, :light_sensor)
      end)
    end

    test "dims without touches, then goes black, and a touch wakes it" do
      # The shortest choices: dim after 15 s, black after 30 s. Rather than
      # wait, the clock is moved by putting the last touch in the past.
      Fp3Extras.Screen.put_settings(dim_after_ms: 15_000, off_after_ms: 30_000)
      wait_for(fn -> display().dim_after_ms == 15_000 end)

      :sys.replace_state(Fp3Extras.Screen, &%{&1 | last_touch: &1.last_touch - 16_000})
      wait_for(fn -> :sys.get_state(Fp3Extras.Screen).mode == :dim end)
      assert Solve.subscribe(@app, :device).screen_on

      # It fades rather than jumping.
      Process.sleep(200)
      %{level: level} = :sys.get_state(Fp3Extras.Screen)
      assert level > 60 * 0.35 and level < 60

      :sys.replace_state(Fp3Extras.Screen, &%{&1 | last_touch: &1.last_touch - 31_000})
      wait_for(fn -> not Solve.subscribe(@app, :device).screen_on end, 3_000)
      assert :sys.get_state(Fp3Extras.Screen).level == 0.0

      Fp3Extras.Screen.touch()
      wait_for(fn -> Solve.subscribe(@app, :device).screen_on end)
      wait_for(fn -> :sys.get_state(Fp3Extras.Screen).level == 60.0 end)

      Fp3Extras.Screen.toggle()
      wait_for(fn -> not Solve.subscribe(@app, :device).screen_on end, 3_000)
      Fp3Extras.Screen.toggle()
      wait_for(fn -> Solve.subscribe(@app, :device).screen_on end)
    end

    test "dimming at or after turning off is turned off" do
      Solve.dispatch(@app, :settings, :display, {:dim_after_ms, 120_000})
      Solve.dispatch(@app, :settings, :display, {:off_after_ms, 60_000})
      wait_for(fn -> display().off_after_ms == 60_000 and display().dim_after_ms == nil end)
    end

    test "brightness fades to what's set" do
      Solve.dispatch(@app, :settings, :brightness, 30)
      wait_for(fn -> display().brightness == 30 end)
      wait_for(fn -> :sys.get_state(Fp3Extras.Screen).level == 30.0 end)
    end

    test "automatic brightness follows the light" do
      Application.put_env(:fp3_extras, :light_sensor, host_light: 0.00075)
      Solve.dispatch(@app, :settings, :display, {:auto, true})
      wait_for(fn -> display().auto and display().light == "Dim" end)
      assert display().level in 25..35

      Application.put_env(:fp3_extras, :light_sensor, host_light: 0.3)
      Solve.dispatch(@app, :settings, :measure_light, nil)
      wait_for(fn -> display().light == "Very bright" and display().level > 90 end)
    end
  end

  defp display, do: Solve.subscribe(@app, :device).display

  test "renders every screen" do
    {_, log} = with_log(&render_every_screen/0)
    refute log =~ "rerender failed"
  end

  defp render_every_screen do
    viewport =
      start_supervised!(
        {NervesPhone.UI,
         backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
      )

    assert_receive {:emerge_skia_frame, _frame}, 5_000
    snapshot(viewport, "1-home")

    Solve.dispatch(@app, :shell, :open, Settings)
    wait_for(fn -> Solve.subscribe(@app, :shell).active == Settings end)
    snapshot(viewport, "2-wifi")

    neighbours = Enum.find(settings().access_points, &(&1.ssid == "Neighbours"))
    Solve.dispatch(@app, :settings, :pick, neighbours)
    Solve.dispatch(@app, :settings, :key, {:text, "p"})
    Solve.dispatch(@app, :settings, :key, {:text, "w"})
    snapshot(viewport, "3-join")

    Solve.dispatch(@app, :settings, :key, {:layer, :symbols})
    snapshot(viewport, "4-join-symbols")

    Solve.dispatch(@app, :settings, :show, :network)
    snapshot(viewport, "5-network")

    Solve.dispatch(@app, :settings, :show, :display)
    snapshot(viewport, "6-display")

    Application.put_env(:fp3_extras, :light_sensor, host_light: 0.00075)
    Solve.dispatch(@app, :settings, :display, {:auto, true})
    wait_for(fn -> display().light != nil end)
    snapshot(viewport, "6-display-auto")
    Solve.dispatch(@app, :settings, :display, {:auto, false})
    Application.delete_env(:fp3_extras, :light_sensor)

    Solve.dispatch(@app, :settings, :show, :device)
    wait_for(fn -> settings().info != [] end)
    snapshot(viewport, "6-device")

    Solve.dispatch(@app, :settings, :show, :tailscale)
    snapshot(viewport, "6-tailscale-unavailable")

    host_tailscale(%{state: "NeedsLogin"})
    snapshot(viewport, "6-tailscale-logged-out")

    host_tailscale(%{
      state: "NeedsLogin",
      logging_in: true,
      auth_url: "https://login.tailscale.com/a/1a2b3c4d5e6f7"
    })

    snapshot(viewport, "6-tailscale-qr")

    host_tailscale(%{
      state: "Running",
      name: "nerves-6a3a.tail1234.ts.net",
      ip: "100.101.102.103",
      tailnet: "lars@underjord.io"
    })

    snapshot(viewport, "6-tailscale-connected")
    Application.delete_env(:nerves_phone, :tailscale)

    Solve.dispatch(@app, :settings, :show, :security)
    snapshot(viewport, "6-security")

    Solve.dispatch(@app, :settings, :toggle_cookie_shown, nil)
    snapshot(viewport, "6-security-cookie-shown")

    Solve.dispatch(@app, :settings, :edit_cookie, nil)
    Solve.dispatch(@app, :settings, :key, {:text, " "})
    Solve.dispatch(@app, :settings, :key, :action)
    snapshot(viewport, "6-cookie-invalid")

    Solve.dispatch(@app, :settings, :show, :wifi)
    Solve.dispatch(@app, :settings, :toggle_wifi, nil)
    snapshot(viewport, "7-wifi-off")
    Solve.dispatch(@app, :settings, :toggle_wifi, nil)

    # Held sideways (locked to landscape, as the host has no
    # accelerometer).
    orient(:landscape)
    snapshot(viewport, "8-landscape-wifi")

    Solve.dispatch(@app, :settings, :show, :display)
    snapshot(viewport, "8-landscape-display")

    neighbours = Enum.find(settings().access_points, &(&1.ssid == "Neighbours"))
    Solve.dispatch(@app, :settings, :pick, neighbours)
    snapshot(viewport, "8-landscape-join")

    Solve.dispatch(@app, :shell, :home, nil)
    snapshot(viewport, "8-landscape-home")
    orient(:portrait)
  end

  test "landscape is picked in Settings, and kept" do
    Solve.dispatch(@app, :shell, :open, Settings)
    Solve.dispatch(@app, :settings, :display, {:rotation, :landscape})
    wait_for(fn -> device().orientation.orientation == :landscape_left end)
    assert Fp3Extras.Orientation.current().mode == :landscape

    Solve.dispatch(@app, :settings, :display, {:rotation, :portrait})
    wait_for(fn -> device().orientation.orientation == :portrait end)
  end

  test "readings point to an orientation only when clearly tilted" do
    alias Fp3Extras.Orientation
    g = 9.81

    assert Orientation.classify(%{x: 0.0, y: g}) == :portrait
    assert Orientation.classify(%{x: g, y: 0.0}) == :landscape_left
    assert Orientation.classify(%{x: -g, y: 0.0}) == :landscape_right
    assert Orientation.classify(%{x: 0.0, y: -g}) == :upside_down
    # Flat on a table, and halfway between portrait and landscape.
    assert Orientation.classify(%{x: 0.5, y: 0.5}) == nil
    assert Orientation.classify(%{x: 0.7 * g, y: 0.7 * g}) == nil
    # Tilted 20° from upright still counts.
    assert Orientation.classify(%{x: g * :math.sin(0.35), y: g * :math.cos(0.35)}) == :portrait
  end

  defp settings, do: Solve.subscribe(@app, :settings)

  defp device, do: Solve.subscribe(@app, :device)

  defp orient(mode) do
    Fp3Extras.Orientation.put_mode(mode)
    expected = if mode == :landscape, do: :landscape_left, else: :portrait
    wait_for(fn -> device().orientation.orientation == expected end)
  end

  # What NervesPhone.Tailscale reports on the host, shown at the next poll.
  defp host_tailscale(info) do
    Application.put_env(:nerves_phone, :tailscale, host_info: info)
    Solve.dispatch(@app, :settings, :show, :tailscale)
    wait_for(fn -> settings().tailscale.state == info.state end)
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
