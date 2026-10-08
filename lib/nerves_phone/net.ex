defmodule NervesPhone.Net do
  @moduledoc """
  The network, as Settings and the title bar see it.

  On the phone it's VintageNet: reads are property lookups (cheap), and
  changes configure `wlan0`. Turning Wi-Fi off configures `wlan0` as
  VintageNet's null technology and keeps its configuration in
  `state_dir/wlan0.config`, so turning it on again rejoins the same
  network. Without a kept configuration, it goes back to the one in
  `config/fp3.exs`.

  On the host there's no VintageNet, so an in-memory stand-in with a few
  sample networks takes its place, and joining or forgetting a network
  works on that.
  """

  @typedoc "Wi-Fi as configured and as it is."
  @type wifi :: %{
          enabled: boolean(),
          ssid: String.t() | nil,
          current: %{ssid: String.t(), signal_percent: integer(), band: String.t()} | nil,
          connection: :disconnected | :lan | :internet,
          addresses: [String.t()]
        }

  @typedoc "A network found by a scan."
  @type access_point :: %{
          ssid: String.t(),
          signal_percent: integer(),
          band: String.t(),
          security: :open | :psk | :sae | :eap
        }

  @typedoc "A network interface."
  @type interface :: %{
          name: String.t(),
          connection: :disconnected | :lan | :internet,
          lower_up: boolean(),
          mac: String.t() | nil,
          addresses: [String.t()]
        }

  @doc "Signal strength in four bars."
  def bars(percent) when is_integer(percent), do: min(div(percent, 25) + 1, 4)
  def bars(_percent), do: nil

  @doc """
  The best connection for the title bar: Wi-Fi, then cellular, then wired,
  then USB, preferring one with internet.
  """
  def status do
    candidates = [{:wifi, "wlan0"}, {:cellular, "rmnet0"}, {:ethernet, "eth0"}, {:usb, "usb0"}]
    by_name = Map.new(interfaces(), &{&1.name, &1})

    states =
      for {kind, ifname} <- candidates,
          %{connection: conn} <- [by_name[ifname]],
          conn in [:internet, :lan],
          do: {kind, ifname, conn}

    case Enum.find(states, &(elem(&1, 2) == :internet)) || List.first(states) do
      nil ->
        %{kind: :offline, internet: false, bars: nil}

      {kind, ifname, conn} ->
        %{kind: kind, internet: conn == :internet, bars: signal(kind, ifname)}
    end
  end

  defp signal(:wifi, _ifname), do: wifi().current |> then(&(&1 && bars(&1.signal_percent)))
  defp signal(:cellular, ifname), do: cellular_bars(ifname)
  defp signal(_kind, _ifname), do: nil

  # One entry per name, the strongest, strongest first. Hidden networks
  # have no name and aren't listed.
  defp dedupe(access_points) do
    access_points
    |> Enum.reject(&(&1.ssid in [nil, ""]))
    |> Enum.group_by(& &1.ssid)
    |> Enum.map(fn {_ssid, aps} -> Enum.max_by(aps, & &1.signal_percent) end)
    |> Enum.sort_by(&{-&1.signal_percent, &1.ssid})
  end

  if Mix.target() == :host do
    use Agent

    @samples [
      %{ssid: "Workshop", signal_percent: 82, band: "5 GHz", security: :psk},
      %{ssid: "Workshop", signal_percent: 64, band: "2.4 GHz", security: :psk},
      %{ssid: "Café Guest", signal_percent: 55, band: "2.4 GHz", security: :open},
      %{ssid: "Office", signal_percent: 38, band: "5 GHz", security: :eap},
      %{ssid: "Neighbours", signal_percent: 20, band: "2.4 GHz", security: :sae},
      %{ssid: "", signal_percent: 40, band: "2.4 GHz", security: :psk}
    ]

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{enabled: true, ssid: "Workshop"} end, name: __MODULE__)
    end

    @doc "Back to Wi-Fi on and joined to \"Workshop\" (for tests)."
    def reset, do: Agent.update(__MODULE__, fn _ -> %{enabled: true, ssid: "Workshop"} end)

    def wifi do
      %{enabled: enabled, ssid: ssid} = Agent.get(__MODULE__, & &1)
      current = enabled && ssid && Enum.find(access_points(), &(&1.ssid == ssid))

      %{
        enabled: enabled,
        ssid: if(enabled, do: ssid),
        current: if(current, do: Map.take(current, [:ssid, :signal_percent, :band])),
        connection: if(current, do: :internet, else: :disconnected),
        addresses: if(current, do: ["192.168.1.42/24"], else: [])
      }
    end

    def access_points do
      if Agent.get(__MODULE__, & &1.enabled), do: dedupe(@samples), else: []
    end

    def scan, do: :ok

    def set_wifi(enabled), do: Agent.update(__MODULE__, &%{&1 | enabled: enabled})

    def join(ssid, passphrase, _security \\ :psk) do
      if passphrase not in [nil, ""] and byte_size(passphrase) < 8,
        do: {:error, :password_too_short},
        else: Agent.update(__MODULE__, &%{&1 | enabled: true, ssid: ssid})
    end

    def forget, do: Agent.update(__MODULE__, &%{&1 | ssid: nil})

    def interfaces do
      wifi = wifi()

      [
        %{
          name: "usb0",
          connection: :lan,
          lower_up: true,
          mac: "02:00:00:00:00:01",
          addresses: ["172.31.36.97/30"]
        }
      ] ++
        if wifi.enabled do
          [
            %{
              name: "wlan0",
              connection: wifi.connection,
              lower_up: wifi.current != nil,
              mac: "00:0a:f5:12:34:56",
              addresses: wifi.addresses
            }
          ]
        else
          []
        end
    end

    def name_servers, do: if(wifi().current, do: ["192.168.1.1"], else: [])

    defp cellular_bars(_ifname), do: nil
  else
    def wifi do
      config = VintageNet.get(["interface", "wlan0", "config"]) || %{}
      enabled = config[:type] == VintageNetWiFi
      network = config |> get_in([:vintage_net_wifi, :networks]) |> List.wrap() |> List.first()

      current =
        case VintageNet.get(["interface", "wlan0", "wifi", "current_ap"]) do
          %{ssid: ssid} = ap when enabled ->
            %{ssid: ssid, signal_percent: ap.signal_percent, band: band_name(ap.band)}

          _ ->
            nil
        end

      %{
        enabled: enabled,
        ssid: network && network[:ssid],
        current: current,
        connection: VintageNet.get(["interface", "wlan0", "connection"]) || :disconnected,
        addresses: addresses("wlan0", [:inet])
      }
    end

    def access_points do
      (VintageNet.get(["interface", "wlan0", "wifi", "access_points"]) || [])
      |> Enum.map(fn ap ->
        %{
          ssid: ap.ssid,
          signal_percent: ap.signal_percent,
          band: band_name(ap.band),
          security: security(ap.flags)
        }
      end)
      |> dedupe()
    end

    # wpa_supplicant's flags, new style (:psk, :sae, ...) and old
    # (:wpa2_psk_ccmp, ...).
    defp security(flags) do
      names = Enum.map(flags, &Atom.to_string/1)

      cond do
        Enum.any?(names, &String.contains?(&1, "eap")) -> :eap
        Enum.any?(names, &String.contains?(&1, "psk")) -> :psk
        Enum.any?(names, &String.contains?(&1, "sae")) -> :sae
        Enum.any?(names, &(&1 in ["wep", "wpa", "wpa2"])) -> :psk
        true -> :open
      end
    end

    defp band_name(:wifi_2_4_ghz), do: "2.4 GHz"
    defp band_name(:wifi_5_ghz), do: "5 GHz"
    defp band_name(_band), do: ""

    def scan, do: VintageNet.scan("wlan0")

    def set_wifi(false) do
      config = VintageNet.get_configuration("wlan0")

      if config[:type] == VintageNetWiFi do
        File.mkdir_p(NervesPhone.state_dir())
        File.write(saved_path(), :erlang.term_to_binary(config))
      end

      VintageNet.configure("wlan0", %{type: VintageNet.Technology.Null})
    end

    def set_wifi(true) do
      with {:ok, binary} <- File.read(saved_path()),
           %{type: VintageNetWiFi} = config <- safe_binary_to_term(binary),
           :ok <- VintageNet.configure("wlan0", config) do
        File.rm(saved_path())
        :ok
      else
        _ -> VintageNet.reset_to_defaults("wlan0")
      end
    end

    defp safe_binary_to_term(binary) do
      :erlang.binary_to_term(binary, [:safe])
    rescue
      _ -> nil
    end

    defp saved_path, do: Path.join(NervesPhone.state_dir(), "wlan0.config")

    # WPA3-only networks need SAE; anything else with a password is WPA-PSK.
    def join(ssid, passphrase, security \\ :psk)

    def join(ssid, passphrase, :sae) do
      with {:ok, config} <- VintageNetWiFi.Cookbook.wpa3_sae(ssid, passphrase),
           do: VintageNet.configure("wlan0", config)
    end

    def join(ssid, passphrase, _security), do: VintageNetWiFi.quick_configure(ssid, passphrase)

    def forget do
      VintageNet.configure("wlan0", %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{networks: []},
        ipv4: %{method: :dhcp}
      })
    end

    def interfaces do
      for name <- VintageNet.all_interfaces(), name != "lo" do
        %{
          name: name,
          connection: VintageNet.get(["interface", name, "connection"]) || :disconnected,
          lower_up: VintageNet.get(["interface", name, "lower_up"]) == true,
          mac: VintageNet.get(["interface", name, "mac_address"]),
          addresses: addresses(name, [:inet, :inet6])
        }
      end
    end

    def name_servers do
      for %{address: address} <- VintageNet.get(["name_servers"]) || [],
          do: address |> :inet.ntoa() |> to_string()
    end

    defp addresses(ifname, families) do
      for %{family: family, address: address, prefix_length: prefix} <-
            VintageNet.get(["interface", ifname, "addresses"]) || [],
          family in families,
          do: "#{:inet.ntoa(address)}/#{prefix}"
    end

    defp cellular_bars(ifname) do
      case VintageNet.get(["interface", ifname, "mobile", "signal_4bars"]) do
        bars when is_integer(bars) -> bars
        _ -> nil
      end
    end
  end
end
