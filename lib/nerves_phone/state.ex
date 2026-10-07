defmodule NervesPhone.State do
  @moduledoc """
  The Solve application that holds the phone's UI state.

  Each controller is a small state machine. Viewports subscribe to the
  controllers they render with `Solve.Lookup.solve/2` and send events back
  with `Solve.Lookup.event/3`. Calls to the music service run in tasks, so
  none of these ever wait on the network.

    * `:library` - your playlists and the list filter
    * `:workspace` - the dock, open playlists and albums, search; depends
      on `:library`
    * `:player` - playback and its controls, volume
    * `:device` - battery and network status for the title bar
  """

  use Solve

  alias NervesPhone.State.{Device, Library, Player, Workspace}

  @impl Solve
  def controllers do
    [
      controller!(name: :library, module: Library),
      controller!(name: :workspace, module: Workspace, dependencies: [:library]),
      controller!(name: :player, module: Player),
      controller!(name: :device, module: Device)
    ]
  end
end
