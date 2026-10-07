# NervesPhone

Nerves firmware for the Fairphone 3 / 3+, built on
[`nerves_system_fp3`](https://github.com/mlainez/nerves_system_fp3): a plain
music player. Browse your playlists, open one and pick a track, or search for
songs, albums and playlists. Playback is always shuffled, never "smart"
shuffled, and there are no recommendations or other extras.

* The UI is drawn with [Emerge](https://hexdocs.pm/emerge) on the CPU, straight
  to the panel through DRM, laid out like the mobile half of the "Windowed UI
  Concept": every playlist or album you open is a chip in a dock under the
  toolbar.
* State lives in [Solve](https://hexdocs.pm/solve) controllers.
* The music service is a backend behind `NervesPhone.Music.Backend`. Spotify
  is the one there is: [librespot](https://github.com/librespot-org/librespot)
  streams, and its PCM runs through a [Membrane](https://membrane.stream)
  pipeline to PortAudio.

## Using it

* **Playlists:** your whole library in one scrolling list, All or Mine. Tap one
  to open it.
* **A playlist or album:** its tracks. Tap a track to play from it, or "Shuffle
  play" to start at a random one.
* **Search:** an on-screen keyboard; results come in as you pause typing.
  Songs play their album from that song; albums and playlists open.
* **Playing:** cover art, progress, previous / play-pause / next. A mini player
  with play/pause and next sits above the status bar everywhere else.
* **Buttons:** volume up/down set the volume (the speaker icon in the title
  bar shows it), and a tap on power plays/pauses, as does a headset's button.
* **Screen:** goes dark after 30 s without touches. The next touch wakes it,
  and doesn't press anything.
* **Title bar:** volume, network (Wi-Fi bars, mobile, USB, offline) and battery.

## How it fits together

```
NervesPhone.UI (Emerge)  <->  Solve: library · workspace · player · device
                                        |
                              NervesPhone.Music.Backend
                                        |
                  NervesPhone.Spotify: Web API (lists, search, control)
                                       librespot (Connect device) --PCM--> FIFO
                                                                            |
                         Membrane: FifoSource --> PortAudio.Sink --> ALSA softvol --> speaker
```

* The Web API lists, searches and controls playback but never delivers
  audio. librespot signs in as a Spotify Connect device and streams; the app
  tells Spotify to play on it, and Membrane plays what librespot decodes.
  Reading the FIFO on demand is what paces librespot.
* Every call to the service runs in a task, so neither the UI nor its state
  ever waits on the network.
* Playback progress changes every poll; when that's all that changed and
  Playing isn't on screen, the UI doesn't re-render. Nothing re-renders while
  the screen is off.

### Always shuffle, never smart shuffle

* Playback starts with plain shuffle and repeat-context on, so a playlist or
  album never runs out.
* librespot runs with `--autoplay off`, so nothing gets appended, and
  librespot has no smart shuffle at all.
* Every poll (2 s) checks playback is still on plain shuffle and turns it
  back on if another app changed it.

### Caching

* **Playlists and track lists** are JSON in `state_dir/<backend>/` (on the
  phone `/data/music/spotify/playlists.json` and `tracks/...`). They show
  from disk at once, then are fetched again in the background; the fresh
  copy replaces what's shown, and is saved, only when it differs. Track
  lists fetch 50 tracks a request and, without a cache, show as pages arrive.
* **Cover art** (Playing only) is downloaded on demand into
  `state_dir/covers`, one file at a time, named by a hash of the URL and
  trimmed to the newest 500 at start.

## Layout

| Path | What |
|---|---|
| `lib/nerves_phone/ui.ex` | The main screen: title bar, toolbar, dock, mini player, status bar |
| `lib/nerves_phone/ui/*_view.ex` | Playlists, a playlist/album's tracks, search (with keyboard), Playing |
| `lib/nerves_phone/ui/theme.ex` | Colours, scaling and shared widgets |
| `lib/nerves_phone/state/` | Solve controllers: library, workspace (dock, track lists, search), player, device |
| `lib/nerves_phone/music/` | The backend behaviour, the JSON cache, the cover cache |
| `lib/nerves_phone/spotify.ex`, `spotify/` | The Spotify backend: token store, Web API client, librespot |
| `lib/nerves_phone/audio/` | The FIFO source, the Membrane pipeline and its keeper, volume |
| `lib/nerves_phone/buttons.ex`, `screen.ex` | Hardware buttons and touch activity; the screen timeout |
| `lib/mix/tasks/spotify.login.ex` | `mix spotify.login` |
| `mix.exs` | Also builds librespot (`Mix.Tasks.Compile.Librespot`) and trims the release |
| `rootfs_overlay/etc/asound.conf` | The ALSA software volume control |
| `priv/fonts`, `priv/icons` | IBM Plex Sans (OFL, see `LICENSE.txt`) and SVG icons |
| `config/fp3.exs` | Phone config: display, networking, audio, screen timeout, partition grow |
| `scripts/flash-fp3.sh` | First-time flashing over USB |

## Spotify setup

You need Spotify Premium, both for the Web API in development mode (the app
owner's account) and for librespot to stream.

1. Create an app at https://developer.spotify.com/dashboard. Tick "Web API"
   and add `http://127.0.0.1:8888/callback` as a redirect URI.
2. Log in from the project directory:

   ```sh
   mix spotify.login --client-id YOUR_CLIENT_ID
   ```

   This logs in twice in your browser: once for the Web API with your app,
   and once for librespot with librespot's own client ID (Spotify Connect
   refuses credentials made from another app's token). Both end up in
   `.spotify.json`, which is gitignored and can control your account, so
   keep it private. `--librespot-only` redoes just the second step.
3. Rebuild. The login is read at build time. On first boot the librespot
   credentials are written to its cache in `state_dir/librespot`
   (`/data/spotify` on the phone).

Without librespot credentials, the phone still shows up as "Nerves Phone" in
any Spotify app on the same network. Pick it there once to sign it in.

In development mode, Spotify only returns the track lists of playlists you
own or collaborate on. That doesn't matter here: playback is started by
playlist URI, so playlists you follow play too.

## Running on the host

```sh
mix deps.get
iex -S mix
```

The first compile builds librespot with cargo (a minute or two). The UI opens
in a window and audio plays on the default output device. The phone's
hardware libraries are only included in target builds.

`mix test` runs the controllers against a fake music backend and renders the
screens headless with the CPU raster renderer. Set `UI_SNAPSHOT_DIR=some/dir`
to save them as PNGs.

## Building for the phone

Prerequisites:

* Erlang/OTP and Elixir from `.tool-versions`, and the `nerves_bootstrap` archive.
* A Rust toolchain with the `aarch64-unknown-linux-gnu` target. librespot and
  the `arm_ai` NIF in the AI stack are built from source; librespot is
  cross-compiled with the Nerves toolchain. Emerge's renderer and PortAudio
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
* **Network.** Spotify needs the phone online: build with `FP3_WIFI_SSID` /
  `FP3_WIFI_PASSPHRASE`, or use cellular with `FP3_APN`.
* **Sound.** PortAudio plays on ALSA's default device. `ex_audio` routes the
  FP3+ loudspeaker at boot (`config :ex_audio` in `config/fp3.exs`). The
  original FP3's amplifier needs different mixer controls.
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
