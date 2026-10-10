# NervesPhone

Nerves firmware for the Fairphone 3 / 3+, built on
[`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3): a small
mobile OS. A home screen of apps, a title bar with the network and battery,
and Back and Home at the bottom. Settings is the one app there is.

* The UI is drawn with [Emerge](https://hexdocs.pm/emerge), straight to the
  panel through DRM, in the look of the "Windowed UI Concept": warm grey
  surfaces, a blue accent, raised buttons and sunken wells.
* State lives in [Solve](https://hexdocs.pm/solve) controllers.
* [Membrane](https://membrane.stream) is in for media pipelines, though
  nothing uses it yet.

## Using it

* **Home:** a tile per app. Tap one to open it.
* **Title bar:** the app's name, the network (Wi-Fi bars, mobile, Ethernet,
  USB, offline) and the battery.
* **Bottom bar:** Back (to the app's previous page, or home), what the app is
  doing, and Home.
* **Settings:**
  * *Wi-Fi:* turn it on or off, see the network it's on (and forget it), and
    the networks around. Tap an open network to join it; a protected one asks
    for its password on an on-screen keyboard. Scan looks again.
  * *Network:* each interface's status, addresses and MAC, and the name
    servers.
  * *Display:* brightness on a slider, or automatic, following the light
    the front camera measures. When the screen dims and when it goes black.
  * *Device:* model, hostname, serial number, firmware, kernel, uptime,
    memory, storage and battery.
* **Buttons:** a tap on power turns the screen off or on.
* **Screen:** dims after 30 s without touches and goes black after a minute
  (both set in Settings), fading each time. A touch on the dimmed screen
  brightens it; the touch that wakes a black one doesn't press anything.

## Apps

An app is a module implementing `NervesPhone.App`, listed in
`config :nerves_phone, apps: [...]`. It names itself and its tile, brings its
own Solve controllers (they join `NervesPhone.State`), and renders its
toolbar, content and status line. `NervesPhone.Apps.Settings` is the example.

```
NervesPhone.UI (Emerge)  <->  Solve: shell · device · each app's controllers
                                                |
                                         NervesPhone.Net (VintageNet)
```

Updates from an app that isn't on screen don't re-render, and nothing
re-renders while the screen is off.

## Layout

| Path | What |
|---|---|
| `lib/nerves_phone/ui.ex` | The screen: title bar, home, toolbar, bottom bar |
| `lib/nerves_phone/ui/theme.ex` | Colours, scaling and shared widgets |
| `lib/nerves_phone/ui/keyboard.ex` | The on-screen keyboard |
| `lib/nerves_phone/app.ex` | The app behaviour |
| `lib/nerves_phone/apps/` | The apps: Settings and its controller |
| `lib/nerves_phone/state/` | Solve controllers: shell (which app is open), device |
| `lib/nerves_phone/net.ex` | The network through VintageNet, with a stand-in on the host |
| `lib/nerves_phone/device_info.ex` | Facts about the phone for Settings |
| `lib/nerves_phone/hardware.ex` | Where `fp3_extras` (buttons, screen, orientation) reports into the `:device` controller |
| `mix.exs` | Also trims the release |
| `priv/fonts`, `priv/icons` | IBM Plex Sans (OFL, see `LICENSE.txt`) and SVG icons |
| `config/fp3.exs` | Phone config: display, networking, audio, screen timeout, partition grow |
| `scripts/flash-fp3.sh` | First-time flashing over USB |

## Running on the host

```sh
mix deps.get
iex -S mix
```

The UI opens in a window. There's no VintageNet on the host, so
`NervesPhone.Net` stands in with a few sample networks; joining, forgetting
and turning Wi-Fi off work on those. The phone's hardware libraries are only
included in target builds.

`mix test` runs the controllers and renders the screens headless with the
CPU raster renderer. Set `UI_SNAPSHOT_DIR=some/dir` to save them as PNGs.

## Building for the phone

Prerequisites:

* Erlang/OTP and Elixir from `.tool-versions`, and the `nerves_bootstrap` archive.
* A Rust toolchain with the `aarch64-unknown-linux-gnu` target: the `arm_ai`
  NIF in the AI stack is built from source. Emerge's renderer and PortAudio
  are prebuilt.
* An SSH public key in `~/.ssh`. It's baked into the firmware.

```sh
export MIX_TARGET=fp3
mix deps.get
mix firmware
```

Building on a Mac: Bundlex (Membrane's native builds) archives static
libraries with a plain `ar`, and Apple's `ar` silently drops Linux objects.
`mix.exs` puts `scripts/cross-ar` first on `PATH` for target builds so
the Nerves toolchain's `ar` is used. If you ever built Membrane deps for the
phone without it, clear them:
`rm -rf _build/fp3_dev/lib/{bunch_native,shmex,unifex,membrane_common_c,membrane_portaudio_plugin}`.

Optional build-time settings:

* `FP3_WIFI_SSID` / `FP3_WIFI_PASSPHRASE`: join a Wi-Fi network on first
  boot. The credentials end up in the image.
* `FP3_APN`: enable cellular data with the SIM's APN, e.g. `FP3_APN=internet.be`.

### Flashing

Put the phone in fastboot mode (power it off, hold Volume Down, plug in USB):

```sh
scripts/flash-fp3.sh --build    # builds nerves_phone.img, then flashes it
scripts/flash-fp3.sh            # flashes an image that's already built
```

The script unlocks a stock bootloader, installs lk2nd and writes the image to
`userdata`, which erases the phone's data. `--dry-run` shows what it would do.

After that, update over the network with `mix upload`.

## On the device

* **Display.** Emerge uses the DRM backend on `/dev/dri/card0` (the msm
  display) and reads the touchscreen from `/dev/input`. If the panel stays
  dark, list the outputs with `EmergeSkia.drm_outputs(drm_card: "/dev/dri/card1")`
  and change `drm_card` in `config/fp3.exs`. `ui_scale` scales
  sizes for the panel's ~430 dpi.
* **Network.** Join Wi-Fi from Settings, or build with `FP3_WIFI_SSID` /
  `FP3_WIFI_PASSPHRASE` to join one on first boot. Cellular needs `FP3_APN`.
  Turning Wi-Fi off keeps its settings in `/data/phone/wlan0.config`.
* **Sound.** `ex_audio` routes the loudspeaker and the bottom microphone
  at boot (`config :ex_audio` in `config/fp3.exs`); the route is the same
  for the FP3's AW8898 and the FP3+'s TAS2557 amplifier. Recording from
  ALSA device `mic` (or `hw:0,1`) is mono from the bottom mic. The top
  (noise-reference) mic is off by default; `Fp3Extras.Mic` turns it
  on as a second channel for code that processes the pair itself. Nothing
  in the stack cancels noise or echo for recordings.
* **Brightness.** The panel's backlight is `/sys/class/backlight/*`
  (0..4095 on the FP3). There's no ambient light sensor the kernel exposes,
  so automatic brightness takes two small frames from the front camera
  about once a minute while the screen is fully on (about 1.2 s of
  `cam-snap`), and measures how fast the signal rises with exposure. See
  `Fp3Extras.LightSensor` for how, and `config :fp3_extras,
  :light_sensor, dark: ..., bright: ...` to recalibrate.
* **Hardware libraries**, all started at boot: `ex_qcom_smgr` (sensors),
  `fp3_camera`, `ex_audio`, `ex_nfc`, `ex_location` (GPS), `blue_heron`
  (Bluetooth LE), `fp3_modem` / `vintage_net_qmi` (cellular), `input_event`
  (buttons), and `ex_rmtfs`, `ex_remoteproc` and `ex_qbootctl` for modem
  storage, DSP start-up and boot slots.
* **AI stack.** [`nerves_ai`](https://github.com/mlainez/nerves_ai) brings
  Nx on the CPU (`nx_arm`), YOLO, Whisper and small LLMs. Models aren't in the
  image: fetch them with `NervesModelHub.ensure_one/2` once the phone is online.
* **Storage.** On first boot `nerves_ai` grows the data partition to fill
  `userdata`.
