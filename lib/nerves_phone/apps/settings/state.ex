defmodule NervesPhone.Apps.Settings.State do
  @moduledoc """
  Settings' controller: which page is shown, Wi-Fi and the networks
  around, the network interfaces, facts about the phone, the tailnet
  (`NervesPhone.Tailscale`), and Erlang distribution and its cookie
  (`NervesPhone.Distribution`). Display
  settings are passed on to `NervesPhone.Screen`, which keeps them and
  reports them through the `:device` controller.

  Pages are `:wifi`, `:network`, `:display`, `:device`, `:tailscale`,
  `:security`,
  `:join` while typing a network's password, and `:cookie` while typing
  a new cookie. The network is read through `NervesPhone.Net` every
  two seconds (cheap reads); the device facts only while their page is
  shown, as they run `df`, and Tailscale's too, as it runs the CLI. Changes to the network run in tasks, so the
  controller never waits on VintageNet.

  Scans run when Wi-Fi is shown or turned on, and on Scan. Their results
  arrive with later reads, so "Scanning…" shows for a few seconds.
  """

  use Solve.Controller,
    events: [
      :opened,
      :show,
      :scan,
      :toggle_wifi,
      :pick,
      :key,
      :toggle_shown,
      :join,
      :forget,
      :display,
      :brightness,
      :measure_light,
      :toggle_cookie_shown,
      :edit_cookie,
      :save_cookie,
      :new_cookie,
      :tailscale_login
    ]

  alias NervesPhone.{DeviceInfo, Distribution, Net, Screen, Tailscale}

  @poll_ms 2_000
  @scan_ms 5_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :poll)
    send(self(), :scan)

    %{
      page: :wifi,
      wifi: Net.wifi(),
      access_points: Net.access_points(),
      scanning: false,
      interfaces: Net.interfaces(),
      name_servers: Net.name_servers(),
      info: [],
      join: nil,
      distribution: Distribution.status(),
      tailscale: nil,
      cookie: nil,
      cookie_shown: false,
      cookie_edit: nil
    }
  end

  # The app was opened from the home screen.
  def opened(_payload, state) do
    if state.page == :wifi, do: send(self(), :scan)
    state
  end

  def show(page, state)
      when page in [:wifi, :network, :display, :device, :tailscale, :security] do
    if page == :wifi, do: send(self(), :scan)

    # The cookie is read when its page is shown, and hidden again.
    cookie =
      if page == :security, do: %{cookie: Distribution.cookie(), cookie_shown: false}, else: %{}

    refresh(Map.merge(%{state | page: page, join: nil, cookie_edit: nil}, cookie))
  end

  def scan(_payload, state) do
    send(self(), :scan)
    state
  end

  def toggle_wifi(_payload, state) do
    enabled = not state.wifi.enabled
    async(fn -> Net.set_wifi(enabled) end)
    if enabled, do: Process.send_after(self(), :scan, 2_000)

    %{
      state
      | wifi: %{state.wifi | enabled: enabled},
        access_points: if(enabled, do: state.access_points, else: [])
    }
  end

  # An open network is joined at once; a protected one asks for its
  # password first. Enterprise networks need more than a password.
  def pick(%{ssid: ssid, security: :open}, state), do: connect(state, ssid, nil, :open)
  def pick(%{security: :eap}, state), do: state

  def pick(%{ssid: ssid, security: security}, state) do
    %{
      state
      | page: :join,
        join: %{
          ssid: ssid,
          security: security,
          password: "",
          shown: false,
          layer: :lower,
          error: nil
        }
    }
  end

  def key(payload, %{page: :cookie} = state), do: cookie_key(payload, state)
  def key(_payload, %{join: nil} = state), do: state

  def key({:text, char}, %{join: join} = state) do
    layer = if join.layer == :upper, do: :lower, else: join.layer
    %{state | join: %{join | password: join.password <> char, layer: layer, error: nil}}
  end

  def key(:backspace, %{join: join} = state) do
    password = String.slice(join.password, 0..-2//1)
    %{state | join: %{join | password: password, error: nil}}
  end

  def key({:layer, layer}, %{join: join} = state), do: %{state | join: %{join | layer: layer}}
  def key(:action, state), do: join(nil, state)

  def toggle_shown(_payload, %{join: nil} = state), do: state

  def toggle_shown(_payload, %{join: join} = state),
    do: %{state | join: %{join | shown: not join.shown}}

  def join(_payload, %{join: nil} = state), do: state

  def join(_payload, %{join: join} = state) do
    case validate(join.password) do
      :ok -> connect(state, join.ssid, join.password, join.security)
      {:error, message} -> %{state | join: %{join | error: message}}
    end
  end

  # A display setting: `{:auto, true}`, `{:dim_after_ms, 30_000}`, ...
  def display({:rotation, mode}, state) do
    NervesPhone.Orientation.put_mode(mode)
    state
  end

  def display({key, value}, state) do
    Screen.put_settings(%{key => value})
    state
  end

  # From the slider.
  def brightness(value, state) when is_number(value) do
    Screen.put_settings(%{brightness: value})
    state
  end

  def measure_light(_payload, state) do
    Screen.measure()
    state
  end

  def toggle_cookie_shown(_payload, state), do: %{state | cookie_shown: not state.cookie_shown}

  # Typing a new cookie starts from the current one.
  def edit_cookie(_payload, state) do
    %{state | page: :cookie, cookie_edit: %{text: state.cookie, layer: :lower, error: nil}}
  end

  def save_cookie(_payload, %{cookie_edit: nil} = state), do: state

  def save_cookie(_payload, %{cookie_edit: edit} = state) do
    case Distribution.put_cookie(edit.text) do
      :ok -> show(:security, state)
      {:error, message} -> %{state | cookie_edit: %{edit | error: message}}
    end
  end

  def new_cookie(_payload, state) do
    _ = Distribution.regenerate_cookie()
    %{state | cookie: Distribution.cookie()}
  end

  # The QR code shows once tailscaled has a login URL, at a later poll.
  def tailscale_login(_payload, state) do
    async(&Tailscale.login/0)
    %{state | tailscale: state.tailscale && %{state.tailscale | logging_in: true}}
  end

  def forget(_payload, state) do
    async(fn -> Net.forget() end)
    %{state | wifi: %{state.wifi | ssid: nil, current: nil}}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    refresh(state)
  end

  def handle_info(:scan, state) do
    if state.wifi.enabled do
      async(fn -> Net.scan() end)
      Process.send_after(self(), :scan_done, @scan_ms)
      %{state | scanning: true}
    else
      state
    end
  end

  def handle_info(:scan_done, state), do: refresh(%{state | scanning: false})

  def handle_info(_message, state), do: state

  defp cookie_key({:text, char}, %{cookie_edit: edit} = state) do
    layer = if edit.layer == :upper, do: :lower, else: edit.layer
    %{state | cookie_edit: %{edit | text: edit.text <> char, layer: layer, error: nil}}
  end

  defp cookie_key(:backspace, %{cookie_edit: edit} = state) do
    %{state | cookie_edit: %{edit | text: String.slice(edit.text, 0..-2//1), error: nil}}
  end

  defp cookie_key({:layer, layer}, %{cookie_edit: edit} = state),
    do: %{state | cookie_edit: %{edit | layer: layer}}

  defp cookie_key(:action, state), do: save_cookie(nil, state)

  # The same checks VintageNet makes, so the message can say what's wrong.
  defp validate(password) do
    cond do
      byte_size(password) < 8 -> {:error, "The password is at least 8 characters."}
      byte_size(password) > 63 -> {:error, "The password is at most 63 characters."}
      true -> :ok
    end
  end

  defp connect(state, ssid, password, security) do
    async(fn -> Net.join(ssid, password, security) end)

    %{
      state
      | page: :wifi,
        join: nil,
        wifi: %{state.wifi | enabled: true, ssid: ssid, current: nil}
    }
  end

  defp refresh(state) do
    %{
      state
      | wifi: Net.wifi(),
        access_points: Net.access_points(),
        interfaces: Net.interfaces(),
        name_servers: Net.name_servers(),
        info: if(state.page == :device, do: DeviceInfo.read(), else: state.info),
        tailscale: if(state.page == :tailscale, do: Tailscale.info(), else: state.tailscale),
        distribution: Distribution.status()
    }
  end

  defp async(fun), do: Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fun)
end
