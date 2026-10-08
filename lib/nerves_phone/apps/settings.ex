defmodule NervesPhone.Apps.Settings do
  @moduledoc """
  Settings: Wi-Fi, the network, and the phone itself.

    * **Wi-Fi** - on or off, the network it's on (with Forget), and the
      networks around. Tapping an open network joins it; a protected one
      asks for its password, typed on `NervesPhone.UI.Keyboard`.
    * **Network** - every interface with its connection, addresses and MAC,
      and the name servers.
    * **Display** - brightness, by hand or following the light the front
      camera measures, when the screen dims and goes black
      (`NervesPhone.Screen`), and whether the screen turns with the phone
      (`NervesPhone.Orientation`).
    * **Device** - model, hostname, serial number, firmware, system,
      memory, storage and battery (`NervesPhone.DeviceInfo`).
    * **Tailscale** - whether the phone is on the tailnet, its name and
      address there, and logging in with a QR code to scan
      (`NervesPhone.Tailscale`).
    * **Security** - the phone as an Erlang distribution node: its name,
      the nodes connected, and the cookie, hidden until shown, typed on
      the keyboard or made up at random (`NervesPhone.Distribution`).

  State is in `NervesPhone.Apps.Settings.State`.
  """

  @behaviour NervesPhone.App

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2, event: 2, event: 3]

  alias NervesPhone.{Net, Screen}
  alias NervesPhone.UI.Keyboard

  @app NervesPhone.State

  @impl NervesPhone.App
  def name, do: "Settings"

  @impl NervesPhone.App
  def icon, do: :settings

  @impl NervesPhone.App
  def tile, do: {{120, 132, 150}, {58, 68, 86}}

  @impl NervesPhone.App
  def controllers, do: [[name: :settings, module: NervesPhone.Apps.Settings.State]]

  @impl NervesPhone.App
  def opened, do: Solve.dispatch(@app, :settings, :opened, nil)

  @impl NervesPhone.App
  def toolbar do
    settings = solve(@app, :settings)

    page =
      case settings.page do
        :join -> :wifi
        :cookie -> :security
        page -> page
      end

    [
      {:wifi, "Wi-Fi", event(settings, :show, :wifi), page == :wifi},
      {:network, "Network", event(settings, :show, :network), page == :network},
      {:sun, "Display", event(settings, :show, :display), page == :display},
      {:device, "Device", event(settings, :show, :device), page == :device},
      {:tailnet, "Tailscale", event(settings, :show, :tailscale), page == :tailscale},
      {:lock, "Security", event(settings, :show, :security), page == :security}
    ] ++
      if page == :wifi and settings.wifi.enabled,
        do: [:separator, {:refresh, "Scan", event(settings, :scan, nil), settings.scanning}],
        else: []
  end

  @impl NervesPhone.App
  def status do
    settings = solve(@app, :settings)
    wifi = settings.wifi

    case settings.page do
      :join ->
        "Joining “#{settings.join.ssid}”"

      :wifi ->
        cond do
          not wifi.enabled -> "Wi-Fi is off"
          wifi.current -> "Connected to “#{wifi.current.ssid}”"
          wifi.ssid -> "Connecting to “#{wifi.ssid}”…"
          settings.scanning -> "Scanning…"
          true -> "Not connected"
        end

      :network ->
        up = Enum.count(settings.interfaces, &(&1.connection != :disconnected))
        "#{up} of #{length(settings.interfaces)} interfaces connected"

      :display ->
        case solve(@app, :device).display do
          nil -> ""
          %{auto: true, measuring: true} -> "Measuring the light…"
          %{auto: true, light: light, level: level} when light != nil -> "#{light} · #{level}%"
          %{level: level} -> "Brightness #{level}%"
        end

      :device ->
        solve(@app, :device).hostname

      :tailscale ->
        if settings.tailscale, do: tailscale_state(settings.tailscale), else: ""

      :security ->
        case settings.distribution do
          %{alive: false} -> "Distribution isn't running"
          %{nodes: []} -> "No nodes connected"
          %{nodes: [_node]} -> "1 node connected"
          %{nodes: nodes} -> "#{length(nodes)} nodes connected"
        end

      :cookie ->
        "Changing the cookie"
    end
  end

  @impl NervesPhone.App
  def back do
    settings = solve(@app, :settings)

    case settings.page do
      :join -> event(settings, :show, :wifi)
      :cookie -> event(settings, :show, :security)
      _page -> nil
    end
  end

  @impl NervesPhone.App
  def render do
    settings = solve(@app, :settings)

    case settings.page do
      :wifi -> wifi(settings)
      :join -> join(settings)
      :network -> network(settings)
      :display -> display(settings, solve(@app, :device))
      :device -> device(settings, solve(@app, :device))
      :tailscale -> tailscale_page(settings, settings.tailscale)
      :security -> security_page(settings)
      :cookie -> cookie_page(settings)
    end
  end

  # ---------- Wi-Fi ----------

  defp wifi(settings) do
    wifi = settings.wifi

    switch_row =
      row(
        [
          key(:wifi_switch),
          width(fill()),
          padding_xy(s(12), s(12)),
          spacing(s(10)),
          Background.color(vgrad(:s0, :s1)),
          Border.width_each(0, 0, 1, 0),
          Border.color(c(:text, 0.06))
        ],
        [
          el([center_y()], icon(:wifi, 20, c(:text))),
          el([center_y(), width(fill()), Font.size(s(15)), Font.medium()], text("Wi-Fi")),
          switch(wifi.enabled, event(settings, :toggle_wifi, nil))
        ]
      )

    rows =
      if wifi.enabled do
        current(settings) ++ networks(settings)
      else
        [
          el(
            [key(:off), width(fill())],
            message(["Wi-Fi is off.", "Turn it on to see the networks around."])
          )
        ]
      end

    scroll_list([switch_row | rows])
  end

  # The network Wi-Fi is set to join, connected or not.
  defp current(%{wifi: %{ssid: nil}}), do: []

  defp current(%{wifi: wifi} = settings) do
    {meta, trailing} =
      cond do
        wifi.current && wifi.connection == :internet ->
          {"Connected · #{Enum.join(wifi.addresses, ", ")}", bars(wifi.current.signal_percent)}

        wifi.current ->
          {"Connected, no internet · #{Enum.join(wifi.addresses, ", ")}",
           bars(wifi.current.signal_percent)}

        true ->
          {"Connecting…", ""}
      end

    [
      section("Current network"),
      list_row({:current, wifi.ssid}, nil, wifi.ssid, meta, trailing, wifi.current != nil),
      el(
        [key(:forget), width(fill()), padding_each(s(8), s(12), s(4), s(12))],
        button("Forget this network", event(settings, :forget, nil), color: c(:red))
      )
    ]
  end

  defp networks(settings) do
    others = Enum.reject(settings.access_points, &(&1.ssid == settings.wifi.ssid))

    found =
      for ap <- others do
        list_row(
          {:ap, ap.ssid},
          if(ap.security != :eap, do: event(settings, :pick, ap)),
          ap.ssid,
          Enum.join([security(ap.security), ap.band] |> Enum.reject(&(&1 == "")), " · "),
          row([spacing(s(8))], [
            if(ap.security == :open,
              do: none(),
              else: el([center_y()], icon(:lock, 12, c(:dim)))
            ),
            el([center_y()], bars(ap.signal_percent))
          ])
        )
      end

    empty =
      if settings.scanning,
        do: message(["Looking for networks…"]),
        else: message(["No networks found.", "Tap Scan to look again."])

    [
      section("Networks")
      | if(found == [], do: [el([key(:empty), width(fill())], empty)], else: found)
    ]
  end

  defp security(:open), do: "Open"
  defp security(:psk), do: "WPA password"
  defp security(:sae), do: "WPA3 password"
  defp security(:eap), do: "Enterprise, not supported"

  defp bars(percent), do: signal_bars(Net.bars(percent), c(:text))

  # ---------- Joining ----------

  defp join(%{join: join} = settings) do
    password =
      cond do
        join.password == "" -> el([Font.color(c(:faint))], text("Password"))
        join.shown -> text(join.password)
        true -> text(String.duplicate("•", String.length(join.password)))
      end

    field =
      row([width(fill()), spacing(s(8))], [
        el(
          [
            width(fill()),
            height(px(s(44))),
            padding_xy(s(12), 0),
            Border.rounded(s(2)),
            Background.color(c(:s0)),
            Font.size(s(15))
          ] ++ sunken(),
          row([center_y(), spacing(s(1))], [
            password,
            # The caret.
            el([width(px(s(1.5))), height(px(s(18))), Background.color(c(:acc_from))], none())
          ])
        ),
        button(
          icon(:eye, 18, if(join.shown, do: c(:acc_from), else: c(:dim))),
          event(settings, :toggle_shown, nil),
          selected: join.shown
        )
      ])

    column([width(fill()), height(fill())], [
      column([width(fill()), height(fill()), padding(s(14)), spacing(s(12))], [
        label("Join network"),
        row([spacing(s(8))], [
          el([center_y()], icon(:lock, 16, c(:text))),
          el([center_y(), Font.size(s(18)), Font.medium()], text(join.ssid))
        ]),
        field,
        if(join.error,
          do: el([Font.size(s(12)), Font.color(c(:red))], text(join.error)),
          else: none()
        ),
        row([width(fill()), spacing(s(8))], [
          button("Cancel", event(settings, :show, :wifi), fill: true),
          button("Join", event(settings, :join, nil), fill: true, primary: true)
        ])
      ]),
      Keyboard.render(join.layer, &event(settings, :key, &1), "Join")
    ])
  end

  # ---------- Network ----------

  defp network(settings) do
    interfaces =
      Enum.flat_map(settings.interfaces, fn iface ->
        [
          section("#{interface_name(iface.name)} · #{iface.name}"),
          info_row({iface.name, :state}, "Status", connection(iface))
        ] ++
          for(
            {address, i} <- Enum.with_index(iface.addresses),
            do: info_row({iface.name, :address, i}, if(i == 0, do: "Address", else: ""), address)
          ) ++
          if(iface.mac, do: [info_row({iface.name, :mac}, "MAC", iface.mac)], else: [])
      end)

    dns =
      if settings.name_servers == [],
        do: [],
        else: [
          section("Name servers")
          | for(
              {server, i} <- Enum.with_index(settings.name_servers),
              do: info_row({:dns, i}, if(i == 0, do: "DNS", else: ""), server)
            )
        ]

    if interfaces == [],
      do: message(["No network interfaces."]),
      else: scroll_list(interfaces ++ dns)
  end

  defp interface_name("wlan" <> _), do: "Wi-Fi"
  defp interface_name("eth" <> _), do: "Ethernet"
  defp interface_name("usb" <> _), do: "USB"
  defp interface_name("rmnet" <> _), do: "Mobile"
  defp interface_name("wwan" <> _), do: "Mobile"
  defp interface_name(_name), do: "Interface"

  defp connection(%{connection: :internet}), do: "Internet"
  defp connection(%{connection: :lan}), do: "Local network only"
  defp connection(%{lower_up: true}), do: "Link up, no address"
  defp connection(_iface), do: "Disconnected"

  # ---------- Display ----------

  defp display(_settings, %{display: nil}), do: message(["Reading…"])

  defp display(settings, %{display: display, orientation: orientation}) do
    auto_row =
      row(
        [
          key(:auto),
          width(fill()),
          padding_xy(s(12), s(10)),
          spacing(s(10)),
          Border.width_each(0, 0, 1, 0),
          Border.color(c(:text, 0.05))
        ],
        [
          column([width(fill()), center_y(), spacing(s(3))], [
            el([Font.size(s(14))], text("Automatic")),
            el(
              [Font.size(s(11)), Font.light(), Font.color(c(:dim))],
              text("Follows the light at the front camera")
            )
          ]),
          switch(display.auto, event(settings, :display, {:auto, not display.auto}))
        ]
      )

    brightness =
      if display.auto do
        light =
          cond do
            display.measuring -> "Measuring…"
            display.light -> display.light
            display.light_error -> "Couldn't measure (#{light_error(display.light_error)})"
            true -> "Not measured yet"
          end

        [
          info_row(:light, "Light", light),
          info_row(:level, "Brightness", "#{display.level}%"),
          el(
            [key(:measure), width(fill()), padding_each(s(8), s(12), s(4), s(12))],
            button("Measure now", event(settings, :measure_light, nil))
          )
        ]
      else
        [
          row(
            [key(:slider), width(fill()), padding_xy(s(12), s(12)), spacing(s(10))],
            [
              el([center_y()], icon(:sun_low, 18, c(:dim))),
              Input.slider(
                [
                  width(fill()),
                  height(px(s(36))),
                  center_y(),
                  Input.Slider.config(
                    min: 5,
                    max: 100,
                    step: 1,
                    track:
                      el(
                        [
                          height(px(s(8))),
                          center_y(),
                          Border.rounded(s(4)),
                          Background.color(vgrad(:s2, :s3))
                        ] ++
                          sunken(),
                        none()
                      ),
                    filled_track:
                      el(
                        [
                          height(px(s(8))),
                          center_y(),
                          Border.rounded(s(4)),
                          Background.color(accent())
                        ],
                        none()
                      ),
                    thumb:
                      el(
                        [
                          width(px(s(26))),
                          height(px(s(26))),
                          Border.rounded(s(13)),
                          Background.color(vgrad(:s0, :s1))
                        ] ++ raised(),
                        none()
                      )
                  ),
                  Event.on_change(event(settings, :brightness))
                ],
                display.brightness
              ),
              el([center_y()], icon(:sun, 20, c(:text)))
            ]
          )
        ]
      end

    dim_choices =
      for ms <- Screen.dim_choices() do
        # Dimming at or after turning off would never happen.
        usable? = ms == nil or display.off_after_ms == nil or ms < display.off_after_ms

        {duration(ms), ms == display.dim_after_ms,
         usable? && event(settings, :display, {:dim_after_ms, ms})}
      end

    off_choices =
      for ms <- Screen.off_choices() do
        {duration(ms), ms == display.off_after_ms, event(settings, :display, {:off_after_ms, ms})}
      end

    scroll_list(
      [section("Brightness"), auto_row] ++
        brightness ++
        [
          section("Dim after"),
          choices(:dim_choices, dim_choices),
          section("Turn off after"),
          choices(:off_choices, off_choices)
        ] ++ rotation(settings, orientation)
    )
  end

  defp rotation(settings, orientation) do
    modes =
      for {mode, label} <- [auto: "Automatic", portrait: "Portrait", landscape: "Landscape"] do
        {label, orientation.mode == mode, event(settings, :display, {:rotation, mode})}
      end

    note =
      if orientation.mode == :auto and not orientation.sensor,
        do: [info_row(:no_sensor, "", "No accelerometer here, so it stays portrait")],
        else: []

    [section("Rotation"), choices(:rotation, modes)] ++ note
  end

  # A row of buttons, one selected; a nil event greys one out.
  defp choices(key, options) do
    wrapped_row(
      [key(key), width(fill()), padding_xy(s(12), s(6)), spacing_xy(s(6), s(6))],
      for {label, selected?, on_press} <- options do
        if on_press,
          do:
            button(label, on_press,
              selected: selected?,
              color: c(if selected?, do: :acc_from, else: :text)
            ),
          else: button(label, nil, color: c(:faint))
      end
    )
  end

  defp duration(nil), do: "Never"
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{div(ms, 60_000)} min"

  defp light_error(:no_camera), do: "no camera"
  defp light_error(:camera_busy), do: "camera in use"
  defp light_error(_reason), do: "camera error"

  # ---------- Device ----------

  defp device(settings, device) do
    battery =
      case device.battery do
        nil ->
          []

        %{level: level, charging: charging} ->
          [
            section("Battery"),
            info_row(:battery, "Charge", "#{level}%#{if charging, do: ", charging", else: ""}"),
            el([key(:battery_bar), width(fill()), padding_xy(s(12), s(8))], progress(level, 100))
          ]
      end

    sections =
      Enum.flat_map(settings.info, fn {title, rows} ->
        [section(title) | for({label, value} <- rows, do: info_row({title, label}, label, value))]
      end)

    if sections == [] and battery == [],
      do: message(["Reading…"]),
      else: scroll_list(sections ++ battery)
  end

  # ---------- Security ----------

  defp security_page(settings) do
    distribution = settings.distribution

    nodes =
      case distribution.nodes do
        [] ->
          [info_row(:no_nodes, "Connected", "None")]

        nodes ->
          for {node, i} <- Enum.with_index(nodes),
              do: info_row({:node, node}, if(i == 0, do: "Connected", else: ""), to_string(node))
      end

    cookie =
      if settings.cookie_shown,
        do: settings.cookie,
        else: String.duplicate("•", Kernel.min(String.length(settings.cookie), 16))

    cookie_row =
      row(
        [
          key(:cookie),
          width(fill()),
          padding_xy(s(12), s(10)),
          spacing(s(10)),
          Border.width_each(0, 0, 1, 0),
          Border.color(c(:text, 0.05))
        ],
        [
          el(
            [width(fill()), center_y(), Font.size(s(14))],
            paragraph([], [text(cookie)])
          ),
          button(
            icon(:eye, 18, if(settings.cookie_shown, do: c(:acc_from), else: c(:dim))),
            event(settings, :toggle_cookie_shown, nil),
            selected: settings.cookie_shown
          )
        ]
      )

    scroll_list(
      [
        section("Erlang distribution"),
        info_row(:status, "Status", if(distribution.alive, do: "Running", else: "Not running")),
        info_row(:node_name, "Node", to_string(distribution.name))
      ] ++
        nodes ++
        [
          section("Cookie"),
          cookie_row,
          row(
            [
              key(:cookie_buttons),
              width(fill()),
              padding_each(s(8), s(12), s(4), s(12)),
              spacing(s(8))
            ],
            [
              button("Change", event(settings, :edit_cookie, nil), fill: true),
              button("New random", event(settings, :new_cookie, nil), fill: true)
            ]
          ),
          el(
            [
              key(:cookie_note),
              width(fill()),
              padding_xy(s(12), s(8)),
              Font.size(s(11)),
              Font.light(),
              Font.color(c(:dim))
            ],
            paragraph([], [
              text(
                "Nodes that know the cookie can connect and run anything on the phone. " <>
                  "A new cookie applies to connections made after."
              )
            ])
          )
        ]
    )
  end

  defp cookie_page(%{cookie_edit: edit} = settings) do
    field =
      el(
        [
          width(fill()),
          height(px(s(44))),
          padding_xy(s(12), 0),
          Border.rounded(s(2)),
          Background.color(c(:s0)),
          Font.size(s(15))
        ] ++ sunken(),
        row([center_y(), spacing(s(1))], [
          if(edit.text == "",
            do: el([Font.color(c(:faint))], text("Cookie")),
            else: text(edit.text)
          ),
          # The caret.
          el([width(px(s(1.5))), height(px(s(18))), Background.color(c(:acc_from))], none())
        ])
      )

    column([width(fill()), height(fill())], [
      column([width(fill()), height(fill()), padding(s(14)), spacing(s(12))], [
        label("Erlang cookie"),
        field,
        if(edit.error,
          do: el([Font.size(s(12)), Font.color(c(:red))], text(edit.error)),
          else: none()
        ),
        row([width(fill()), spacing(s(8))], [
          button("Cancel", event(settings, :show, :security), fill: true),
          button("Save", event(settings, :save_cookie, nil), fill: true, primary: true)
        ])
      ]),
      Keyboard.render(edit.layer, &event(settings, :key, &1), "Save")
    ])
  end

  # ---------- Tailscale ----------

  defp tailscale_page(_settings, nil), do: message(["Reading…"])

  defp tailscale_page(_settings, %{state: "Unavailable"}),
    do: message(["Tailscale doesn't run here.", "It's on the phone, not the host."])

  defp tailscale_page(settings, tailscale) do
    rows =
      for {label, value} <- [
            {"Status", tailscale_state(tailscale)},
            {"Name", tailscale.name},
            {"Address", tailscale.ip},
            {"Tailnet", tailscale.tailnet}
          ],
          value != nil,
          do: info_row({:tailscale, label}, label, value)

    scroll_list([section("Tailscale") | rows] ++ tailscale_login(settings, tailscale))
  end

  defp tailscale_login(_settings, %{state: state})
       when state in ["Running", "Starting", "NoDaemon"],
       do: []

  defp tailscale_login(_settings, %{state: "NeedsMachineAuth"}) do
    [
      el(
        [key(:approval), width(fill())],
        message([
          "Logged in.",
          "An admin has to approve the phone in the Tailscale admin console."
        ])
      )
    ]
  end

  defp tailscale_login(_settings, %{logging_in: true, auth_url: url}) when is_binary(url) do
    [
      section("Log in"),
      el(
        [key(:qr), center_x(), padding(s(12)), Background.color(color_rgb(255, 255, 255))],
        qr_code(url, s(6))
      ),
      el(
        [
          key(:qr_note),
          center_x(),
          padding_xy(s(16), s(6)),
          Font.size(s(12)),
          Font.color(c(:dim))
        ],
        text("Scan with a phone signed in to Tailscale, or visit")
      ),
      el([key(:qr_url), center_x(), padding_xy(s(16), 0), Font.size(s(11))], text(url))
    ]
  end

  defp tailscale_login(_settings, %{logging_in: true}),
    do: [el([key(:waiting), width(fill())], message(["Getting a login link…"]))]

  defp tailscale_login(settings, _tailscale) do
    [
      el(
        [key(:login), width(fill()), padding_each(s(12), s(12), s(4), s(12))],
        button("Log in", event(settings, :tailscale_login, nil), fill: true, primary: true)
      ),
      el(
        [
          key(:login_note),
          width(fill()),
          padding_xy(s(12), s(8)),
          Font.size(s(11)),
          Font.light(),
          Font.color(c(:dim))
        ],
        paragraph([], [
          text(
            "Shows a QR code to scan with a phone that's signed in to Tailscale. " <>
              "The phone then joins your tailnet as one of your devices."
          )
        ])
      )
    ]
  end

  defp tailscale_state(%{state: "Running"}), do: "Connected"
  defp tailscale_state(%{state: "NeedsLogin", logging_in: true}), do: "Logging in…"
  defp tailscale_state(%{state: "NeedsLogin"}), do: "Logged out"
  defp tailscale_state(%{state: "NeedsMachineAuth"}), do: "Waiting for approval"
  defp tailscale_state(%{state: "Starting"}), do: "Connecting…"
  defp tailscale_state(%{state: "Stopped"}), do: "Stopped"
  defp tailscale_state(%{state: "NoDaemon"}), do: "Starting Tailscale…"
  defp tailscale_state(%{state: "Unavailable"}), do: "Not available"
  defp tailscale_state(%{state: state}), do: state

  # Each row of the code as runs of dark and light modules, so a row is a
  # few elements rather than one per module. The matrix has its own
  # quiet zone.
  defp qr_code(url, module) do
    rows = EQRCode.encode(url).matrix |> Tuple.to_list()

    column(
      [],
      for row <- rows do
        runs =
          row
          |> Tuple.to_list()
          |> Enum.chunk_by(& &1)
          |> Enum.map(fn [bit | _] = run ->
            color = if bit == 1, do: color_rgb(0, 0, 0), else: color_rgb(255, 255, 255)

            el(
              [width(px(module * length(run))), height(px(module)), Background.color(color)],
              none()
            )
          end)

        row([], runs)
      end
    )
  end
end
