# A home_base manifest for the host whose camera the Home Video app shows
# on the phones. Run it from a checkout of lawik/home_base:
#
#   mix home.node ../nerves_phone/scripts/home_video_camera.exs \
#     --name home --host <this host's LAN address> --cookie home_cluster_cookie \
#     --backend static \
#     --peers nerves_phone@nerves-6a3a.local,nerves_phone@nerves-a835.local
#
# The node name must be the one in the phones' `config :nerves_phone, :home`
# peers (home@192.168.4.148 there). The camera is AVFoundation device 0 on
# macOS and /dev/video0 on Linux; HOME_CAMERA picks another one. It's only
# open while a phone shows it.

{device, pixel_format} =
  case :os.type() do
    {:unix, :darwin} -> {System.get_env("HOME_CAMERA", "0"), "nv12"}
    _ -> {System.get_env("HOME_CAMERA", "/dev/video0"), "yuyv422"}
  end

[
  device_id: "camera-host",
  capabilities: [
    %{
      id: "cam0",
      kind: :video_in,
      availability: :on_request,
      adapter: Home.Adapters.Video.Camera,
      meta: %{device: device, w: 640, h: 480, fps: 30, pixel_format: pixel_format}
    }
  ]
]
