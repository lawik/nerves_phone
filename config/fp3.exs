import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Membrane logs a lot at debug level; keep the ring buffer useful.
config :logger, level: :info

config :logger, RingLogger,
  max_size: 1024,
  application_levels: %{ssh: :error}

# Emerge draws straight to the panel through DRM/KMS with OpenGL ES on
# the Adreno 506 (Mesa freedreno). This selects the prebuilt aarch64
# DRM/OpenGL NIF, so no Rust/Skia build is needed.
config :emerge, compiled_backends: [drm: [:opengl]]

# The msm DRM device that drives the panel. See EmergeSkia.drm_outputs/1.
#
# Rendered with OpenGL ES on the Adreno 506 (Mesa freedreno). The driver's
# GMEM tiling path hangs on Skia's MSAA depth/stencil attachments, so
# rel/vm.args.eex sets FD_MESA_DEBUG=sysmem to bypass it.
#
# The renderer cache is off: with it, Emerge 0.4.2's DRM presenter can
# skip a scene that arrives while an older one is staged behind a page
# flip (a tap's press style, then the screen it opens). It takes the new
# scene's fingerprint when it submits the old one, then counts the new
# one as already shown, so the screen stays stale until the next touch.
# See can_skip_unchanged_visible_frame in emerge_skia's renderer.rs and
# its use in backend/drm/gl.rs.
config :nerves_phone, :viewport,
  backend: :drm,
  drm_card: "/dev/dri/card0",
  hw_cursor: false,
  rendering_api: :opengl,
  renderer_cache: [enabled: false]

# Scale the UI for the panel's ~430 dpi.
config :nerves_phone, ui_scale: 2.5

# The display until it's changed in Settings (then Fp3Extras.Screen saves it
# in state_dir/display.json): dim after 30 s without touches, black after
# 1 min.
config :nerves_phone, :display,
  brightness: 60,
  auto: false,
  dim_after_ms: 30_000,
  off_after_ms: 60_000

# The phone's own files, such as the Wi-Fi settings kept while Wi-Fi is off,
# and fp3_extras's (the volume, display and orientation settings, the mic
# device). rootfs_overlay/etc/asound.conf loads asound.mic.conf from here.
config :nerves_phone, state_dir: "/data/phone"
config :fp3_extras, state_dir: "/data/phone"

# Use shoehorn to start the main application. nerves_ai runs the
# first-boot F2FS resize (which briefly unmounts /root) before the app
# starts writing to /data.
config :shoehorn, init: [:nerves_runtime, :nerves_pack, :nerves_ai]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

# No models are downloaded at boot: fetch them with
# NervesModelHub.ensure_one/2 when the phone is online.
config :nerves_ai, :models, []

# First-boot grow of the /root partition and its F2FS (idempotent: the
# resizer reports :already_grown once the FS fills userdata). A phone
# flashed with fastboot keeps the image's partition size, so the
# partition itself is grown too, by the system's ops.fw grow-app task.
#
# erlinit mounts /dev/mmcblk0p62p3 (f2fs) at /root, and /data is a
# symlink to /root.
config :nerves_data_resize, :config,
  partition: "/dev/mmcblk0p62p3",
  mount_point: "/root",
  mount_opts: "nodev",
  grow_partition: [
    disk: "/dev/mmcblk0p62",
    ops_fw: "/usr/share/fwup/ops.fw",
    task: "grow-app"
  ]

# Cellular data is optional: the APN depends on the SIM, so it's only
# configured when FP3_APN is set at build time (e.g. FP3_APN=internet.be).
apn = System.get_env("FP3_APN")

modem =
  if apn do
    [
      {"rmnet0",
       %{
         type: VintageNetQMI,
         vintage_net_qmi: %{
           service_providers: [%{apn: apn}],
           provision_uim: true,
           ip_method: :qmi_profile,
           rmnet_child: %{parent: "rmnet_ipa0", mux_id: 1}
         }
       }}
    ]
  else
    []
  end

# wlan0 is always configured, so wpa_supplicant runs and networks can be
# scanned and set at runtime. Build with FP3_WIFI_SSID (and
# FP3_WIFI_PASSPHRASE for a protected network) to join a network on first
# boot. The credentials end up in the image.
wifi_networks =
  case {System.get_env("FP3_WIFI_SSID"), System.get_env("FP3_WIFI_PASSPHRASE")} do
    {nil, _} -> []
    {ssid, passphrase} when passphrase in [nil, ""] -> [%{ssid: ssid, key_mgmt: :none}]
    {ssid, passphrase} -> [%{ssid: ssid, key_mgmt: :wpa_psk, psk: passphrase}]
  end

# Configure the network using vintage_net: USB gadget ethernet to the
# laptop, wired ethernet (USB-C adapter), Wi-Fi and optionally the modem.
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  power_managers:
    if(apn,
      do: [{Fp3Modem.PowerManager, [ifname: "rmnet0", watchdog_timeout: 120_000]}],
      else: []
    ),
  config:
    [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
      {"wlan0",
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{networks: wifi_networks},
         ipv4: %{method: :dhcp}
       }}
    ] ++ modem

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# ALSA routing applied once the sound card is up (ex_audio).
#
# Loudspeaker: the FP3's AW8898 and the FP3+'s TAS2557 both sit on Quinary
# MI2S, so one route serves both. Playback (hw:0,0, MultiMedia1) goes to
# QUIN_MI2S_RX.
#
# Microphone: the phone's two mics are digital mics on the WCD9335 codec,
# DMIC1 at the bottom (the one you speak into) and DMIC2 at the top (the
# noise reference). Capture (hw:0,1, MultiMedia2) comes from SLIMBUS_0_TX,
# fed by the codec's SLIM TX ports; this routes the bottom mic through
# decimator 7 to TX7, so recording is mono by default. The top mic stays
# off until Fp3Extras.Mic.set_secondary(true) adds it on TX8 as a
# second channel; see that module.
config :ex_audio,
  card: 0,
  mixer: [
    {"QUIN_MI2S_RX Audio Mixer MultiMedia1", :on},
    {"Speaker Switch", :on},
    {"MultiMedia2 Mixer SLIMBUS_0_TX", :on},
    {"SLIM TX7 MUX", "DEC7"},
    {"ADC MUX7", "DMIC"},
    {"DMIC MUX7", "DMIC1"},
    {"AIF1_CAP Mixer SLIM TX7", :on}
  ]

# Fp3Extras.Mic switches the top mic through ex_audio. Two-channel capture
# records silence on nerves_system_fp3 v0.2.4 and a channel mismatch crashes
# the kernel, so switching the top mic on is refused until Fp3Extras.Mic is
# started with `experimental: true` (in NervesPhone.Application).

# Bluetooth LE through the kernel's hci0 (the WCN3680 behind btqcomsmd).
# BlueHeron takes the controller over exclusively, so bluetoothd must not
# run.
config :blue_heron,
  transport: [type: :hci_socket, device: 0],
  # Pair without a passkey: nothing on the phone shows one to the user.
  smp: [io_capability: :no_input_no_output]
