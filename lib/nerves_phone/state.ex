defmodule NervesPhone.State do
  @moduledoc """
  The Solve application that holds the phone's UI state.

  Each controller is a small state machine. The viewport subscribes to the
  controllers it renders with `Solve.Lookup.solve/2` and sends events back
  with `Solve.Lookup.event/3`.

    * `:shell` - which app is on screen
    * `:device` - battery, network and screen status for the title bar
    * `:downloads` - the downloads in progress, for the title bar
    * and each app's own (see `NervesPhone.App`)
  """

  use Solve

  alias NervesPhone.App
  alias NervesPhone.State.{Device, Downloads, Shell}

  @impl Solve
  def controllers do
    [
      controller!(name: :shell, module: Shell),
      controller!(name: :device, module: Device),
      controller!(name: :downloads, module: Downloads)
    ] ++ for(app <- App.all(), spec <- app.controllers(), do: controller!(spec))
  end
end
