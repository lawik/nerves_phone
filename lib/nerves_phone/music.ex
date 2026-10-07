defmodule NervesPhone.Music do
  @moduledoc """
  The music player, independent of the service behind it (see
  `NervesPhone.Music.Backend`).
  """

  @doc "Where the player keeps its own files (cover cache, volume)."
  def state_dir do
    Application.get_env(:nerves_phone, :state_dir) ||
      Path.join(System.tmp_dir!(), "nerves_phone")
  end
end
