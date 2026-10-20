defmodule NervesPhone.Apps.HomeVideo do
  @moduledoc """
  Home Video: a camera from the home cluster on this phone, or a video
  call with another phone, with the stream's numbers drawn over it.

    * **Idle** - the cameras in the cluster, each with Show, which shows it
      here (opening it only then), and the phones in the cluster. Call on
      another phone starts a video call: each phone's front camera on the
      other's screen.
    * **Live** - the picture on the whole screen, and over it a panel with
      the camera, size and frame rate, bitrate (with a graph of the last
      seconds), loss, jitter, round trip, packets recovered and keyframes
      asked for, how many phones show it and for how long. A tap hides or
      shows the panel; Stop ends it (Hang up ends a call on both phones).

  The cluster is home_base (`NervesPhone.Home`); the plumbing is
  `NervesPhone.HomeVideo.Broadcast` and `NervesPhone.HomeVideo.Surface`.
  State is in `NervesPhone.Apps.HomeVideo.State`.
  """

  @behaviour NervesPhone.App

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2, event: 3]

  @app NervesPhone.State

  @impl NervesPhone.App
  def name, do: "Home Video"

  @impl NervesPhone.App
  def icon, do: :eye

  @impl NervesPhone.App
  def tile, do: {{40, 160, 140}, {20, 90, 120}}

  @impl NervesPhone.App
  def controllers, do: [[name: :home_video, module: NervesPhone.Apps.HomeVideo.State]]

  @impl NervesPhone.App
  def opened, do: Solve.dispatch(@app, :home_video, :opened, nil)

  @impl NervesPhone.App
  def fullscreen?, do: solve(@app, :home_video).stream != nil

  @impl NervesPhone.App
  def toolbar, do: []

  @impl NervesPhone.App
  def status do
    home = solve(@app, :home_video)

    cond do
      home.stream -> "Live · #{fps(home.stream.fps)} fps"
      not home.running -> "Not in the home cluster yet"
      true -> "#{count(home.cameras, "camera")} · #{count(home.phones, "phone")}"
    end
  end

  @impl NervesPhone.App
  def back do
    home = solve(@app, :home_video)
    if home.stream, do: event(home, :stop, nil)
  end

  @impl NervesPhone.App
  def render do
    home = solve(@app, :home_video)
    if home.stream, do: live(home, home.stream), else: idle(home)
  end

  # ---------- Idle ----------

  defp idle(%{running: false}) do
    message([
      "Not in the home cluster yet",
      "The phone joins once it's on the network. Cameras and phones show up here."
    ])
  end

  defp idle(home) do
    scroll_list(
      [section("Cameras")] ++
        camera_rows(home) ++
        error_row(home.error) ++
        [section("Phones")] ++
        phone_rows(home) ++
        [section("Cluster")] ++
        [info_row(:node, "This phone", Atom.to_string(node()))] ++
        for(peer <- home.nodes, do: info_row({:peer, peer}, "Connected", Atom.to_string(peer)))
    )
  end

  defp camera_rows(%{cameras: []}),
    do: [info_row(:no_cameras, "No cameras", "Start a home_base node with a camera")]

  defp camera_rows(home) do
    for camera <- home.cameras do
      starting? = home.starting == camera.ref

      list_row(
        {:camera, camera.ref},
        nil,
        camera.name,
        if(camera.busy, do: "In use", else: "Idle"),
        button(
          if(starting?, do: "Starting…", else: "Show"),
          if(starting? or home.phones == [], do: nil, else: event(home, :broadcast, camera.ref)),
          primary: true
        )
      )
    end
  end

  defp phone_rows(%{phones: []}), do: [info_row(:no_phones, "No phones", "")]

  defp phone_rows(home) do
    for phone <- home.phones do
      list_row(
        {:phone, phone.ref},
        nil,
        phone.name,
        if(phone.node == node(), do: "This phone", else: ""),
        call_button(home, phone.node)
      )
    end
  end

  # A call needs a front camera at both ends.
  defp call_button(home, peer) do
    fronts = for %{ref: {node, "front"}} <- home.cameras, do: node

    cond do
      peer == node() or peer not in fronts or node() not in fronts -> ""
      home.starting == {:call, peer} -> button("Calling…", nil)
      true -> button("Call", event(home, :call, peer), primary: true)
    end
  end

  defp error_row(nil), do: []

  defp error_row(error) do
    [
      el(
        [key(:error), width(fill()), padding_xy(s(12), s(8)), Font.size(s(12))],
        paragraph([Font.color(c(:red))], [text(error)])
      )
    ]
  end

  # ---------- Live ----------

  defp live(home, stream) do
    Input.button(
      [
        width(fill()),
        height(fill()),
        Background.color(color_rgb(0, 0, 0)),
        Event.on_press(event(home, :toggle_stats, nil)),
        Nearby.in_front(if home.show_stats, do: overlay(home, stream), else: none())
      ],
      video(
        [key({:video, stream.target}), width(fill()), height(fill()), image_fit(:contain)],
        stream.target
      )
    )
  end

  defp overlay(home, stream) do
    column([width(fill()), height(fill()), padding(s(12))], [
      stats_panel(stream),
      el([width(fill()), height(fill())], none()),
      el([align_right()], stop_button(home))
    ])
  end

  defp stats_panel(stream) do
    column(
      [
        padding(s(12)),
        spacing(s(6)),
        Border.rounded(s(8)),
        Background.color(color_rgba(0, 0, 0, 0.6)),
        Font.size(s(12)),
        Font.color(color_rgba(255, 255, 255, 0.92))
      ],
      [
        row([spacing(s(6))], [
          el(
            [
              center_y(),
              width(px(s(8))),
              height(px(s(8))),
              Border.rounded(s(4)),
              Background.color(color_rgb(230, 60, 60))
            ],
            none()
          ),
          el(
            [Font.semi_bold(), Font.size(s(13))],
            text("#{if stream.kind == :call, do: "CALL", else: "LIVE"}  #{camera(stream.camera)}")
          )
        ]),
        stat(
          "#{size(stream.size)} · #{fps(stream.fps)} fps · #{stream.frames} shown · #{stream.dropped} dropped"
        ),
        row([spacing(s(8))], [stat("#{mbps(stream.kbps)} Mbit/s"), graph(stream.kbps_history)]),
        stat(
          "loss #{percent(stream.loss)} (#{stream.lost}) · jitter #{ms(stream.jitter_ms)} · rtt #{ms(stream.rtt_ms)}"
        ),
        stat("recovered #{stream.recovered} · keyframes asked #{stream.keyframes}"),
        stat("on #{count(stream.phones, "phone")} · #{uptime(stream.started_at)}")
      ]
    )
  end

  defp stat(line), do: el([], text(line))

  # The bitrate of the last seconds, newest on the right.
  defp graph([]), do: none()

  defp graph(history) do
    top = Enum.max([1 | history])

    row(
      [center_y(), height(px(s(18))), spacing(s(1))],
      for kbps <- Enum.reverse(history) do
        el(
          [
            align_bottom(),
            width(px(s(2))),
            height(px(Kernel.max(s(1), round(s(18) * kbps / top)))),
            Background.color(color_rgba(120, 220, 190, 0.9))
          ],
          none()
        )
      end
    )
  end

  defp stop_button(home) do
    Input.button(
      [
        padding_xy(s(16), s(10)),
        Border.rounded(s(20)),
        Background.color(color_rgba(0, 0, 0, 0.6)),
        Font.size(s(13)),
        Font.color(c(:white)),
        Event.on_press(event(home, :stop, nil))
      ],
      row([spacing(s(6))], [
        icon(:stop, 14, c(:white)),
        text(if home.stream.kind == :call, do: "Hang up", else: "Stop")
      ])
    )
  end

  # ---------- Formatting ----------

  defp camera(nil), do: ""
  defp camera({node, id}), do: "#{host(node)} · #{id}"

  # nerves_phone@nerves-a835.local is nerves-a835; home@192.168.4.148 is
  # its address.
  defp host(node) do
    [_name, host] = node |> Atom.to_string() |> String.split("@", parts: 2)
    String.trim_trailing(host, ".local")
  end

  defp size({w, h}), do: "#{w}×#{h}"
  defp size(nil), do: "–"

  defp fps(fps), do: :erlang.float_to_binary(fps / 1, decimals: 1)
  defp mbps(kbps), do: :erlang.float_to_binary(kbps / 1000, decimals: 2)
  defp percent(fraction), do: "#{:erlang.float_to_binary(fraction * 100.0, decimals: 1)} %"

  defp ms(nil), do: "–"
  defp ms(value), do: "#{round(value)} ms"

  defp uptime(nil), do: "–"

  defp uptime(started_at) do
    seconds = div(System.system_time(:millisecond) - started_at, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp count(items, noun) when is_list(items), do: count(length(items), noun)
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
