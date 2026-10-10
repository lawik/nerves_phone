defmodule NervesPhone.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
        # Starts a worker by calling: NervesPhone.Worker.start_link(arg)
        # {NervesPhone.Worker, arg},
        {Task.Supervisor, name: NervesPhone.TaskSupervisor},
        # The phone's hardware, from fp3_extras; NervesPhone.Hardware feeds
        # what they report into the :device controller.
        Fp3Extras.Volume,
        Fp3Extras.Mic,
        NervesPhone.Kids.History,
        NervesPhone.Flashcards.Progress,
        NervesPhone.Flashcards.Sound,
        NervesPhone.Python,
        NervesPhone.Downloads,
        NervesPhone.SvtPlay,
        # What phone_remote has queued to download.
        NervesPhone.DownloadQueue
      ] ++
        target_children() ++
        [
          {NervesPhone.State, name: NervesPhone.State},
          {Fp3Extras.Screen,
           notify: &NervesPhone.Hardware.screen_event/1,
           defaults: Application.get_env(:nerves_phone, :display, [])},
          # Which way up the UI is, from the accelerometer.
          {Fp3Extras.Orientation, notify: &NervesPhone.Hardware.orientation_event/1}
        ] ++
        ui_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NervesPhone.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The viewport draws to the screen (or a window on the host). Tests
  # turn it off in config/host.exs.
  defp ui_children() do
    # Registered, so the video player can hand it frames.
    if Application.get_env(:nerves_phone, :start_ui, true),
      do: [
        {NervesPhone.UI, name: NervesPhone.UI},
        # With the UI up, the kernel's console comes off the panel (see
        # Fp3Extras.Console). A no-op on the host.
        {Task, &Fp3Extras.Console.release_panel/0}
      ],
      else: []
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
        # A stand-in for the network, as there's no VintageNet.
        NervesPhone.Net
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
        # The volume and power buttons, and touches for the screen timeout.
        {Fp3Extras.Buttons,
         on_touch: &Fp3Extras.Screen.touch/0,
         on_power_tap: &Fp3Extras.Screen.toggle/0,
         on_volume: &NervesPhone.Hardware.volume_button/1},
        # Keeps the phone on the tailnet.
        NervesPhone.Tailscale,
        # epmd, and the phone as a distribution node.
        NervesPhone.Distribution
      ]
    end
  end
end
