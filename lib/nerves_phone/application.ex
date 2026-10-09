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
        NervesPhone.Audio.Volume,
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
          NervesPhone.Screen,
          # Which way up the UI is, from the accelerometer.
          NervesPhone.Orientation
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
      do: [{NervesPhone.UI, name: NervesPhone.UI}],
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
        # The power button, and touches for the screen timeout.
        NervesPhone.Buttons,
        # Keeps the phone on the tailnet.
        NervesPhone.Tailscale,
        # epmd, and the phone as a distribution node.
        NervesPhone.Distribution
      ]
    end
  end
end
