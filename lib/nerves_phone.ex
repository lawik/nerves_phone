defmodule NervesPhone do
  @moduledoc """
  A small mobile OS for the Fairphone 3 on Nerves: a home screen of apps,
  a title bar, and Back and Home in a bar at the bottom. See
  `NervesPhone.App` for what an app is, and `NervesPhone.UI` for the
  screen.
  """

  @doc "Where the phone keeps its own files (`config :nerves_phone, :state_dir`)."
  def state_dir, do: Application.get_env(:nerves_phone, :state_dir, "/data/phone")
end
