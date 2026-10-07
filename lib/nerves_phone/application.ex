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
        NervesPhone.Music.Covers,
        NervesPhone.Audio.Volume
      ] ++
        backend_children() ++
        audio_children() ++
        [{NervesPhone.State, name: NervesPhone.State}, NervesPhone.Screen] ++
        ui_children() ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NervesPhone.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The music service's own processes (for Spotify: its token store and
  # librespot, which writes PCM into a FIFO).
  defp backend_children() do
    if Application.get_env(:nerves_phone, :start_backend, true),
      do: NervesPhone.Music.Backend.impl().children(),
      else: []
  end

  # The Membrane pipeline plays the backend's FIFO on the sound card. Tests
  # turn these off in config/host.exs.
  defp audio_children() do
    if Application.get_env(:nerves_phone, :start_audio, true),
      do: [NervesPhone.Audio.Keeper],
      else: []
  end

  # The viewport draws to the screen (or a window on the host). Tests
  # turn it off in config/host.exs.
  defp ui_children() do
    if Application.get_env(:nerves_phone, :start_ui, true), do: [NervesPhone.UI], else: []
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
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
        # Volume and power buttons.
        NervesPhone.Buttons
      ]
    end
  end
end
