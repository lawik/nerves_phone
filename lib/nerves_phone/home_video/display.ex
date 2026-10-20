defmodule NervesPhone.HomeVideo.Display do
  @moduledoc """
  The phone's screen as a home_base `:display` capability, for video:

      %{id: "phone_video", kind: :display, adapter: NervesPhone.HomeVideo.Display,
        meta: %{w: 1080, h: 2160}}

  Its endpoint is `NervesPhone.HomeVideo.Surface`, which draws a video
  session's frames in the phone's own UI. The phone's renderer is the UI's,
  so scene-forwarded apps (`Home.Render.show/2`) can't be shown on it.
  """

  @behaviour Home.Adapter

  @impl Home.Adapter
  def init(cap), do: {:ok, %{cap: cap}}

  @impl Home.Adapter
  def start(state), do: {:ok, state}

  @impl Home.Adapter
  def stop(state), do: {:ok, state}

  @impl Home.Adapter
  def endpoint(_state), do: Process.whereis(NervesPhone.HomeVideo.Surface)
end
