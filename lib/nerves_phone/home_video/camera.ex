defmodule NervesPhone.HomeVideo.Camera do
  @moduledoc """
  One of the phone's cameras as a home_base `:video_in` capability:

      %{id: "rear", kind: :video_in, availability: :on_request,
        adapter: {NervesPhone.HomeVideo.Camera, camera: :rear}}

  The stream is H.264 from the phone's hardware encoder, so its endpoint
  is a `Home.Media.H264Relay` on a new `NervesPhone.HomeVideo.CameraFeed`:
  a session sends it on as it is instead of encoding it again. The camera
  only runs while a session's relay is subscribed to the feed.
  """

  @behaviour Home.Adapter

  alias NervesPhone.HomeVideo.CameraFeed

  @impl Home.Adapter
  def init(cap), do: {:ok, %{cap: cap}}

  @impl Home.Adapter
  def start(state), do: {:ok, state}

  @impl Home.Adapter
  def stop(state), do: {:ok, state}

  @impl Home.Adapter
  def endpoint(%{cap: cap}) do
    {:ok, feed} = CameraFeed.start(cap.meta.camera)
    %Home.Media.H264Relay{feed: feed}
  end
end
