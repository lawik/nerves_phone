import Config

# Add configuration that is only needed when running on the host here.

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

# The player's files (covers, volume) and Spotify's (tokens, librespot's
# credential cache), kept in the project.
config :nerves_phone, state_dir: Path.expand("../tmp/music", __DIR__)
config :nerves_phone, :spotify, state_dir: Path.expand("../tmp/spotify", __DIR__)

# librespot as built by the :librespot compiler (see mix.exs).
config :nerves_phone,
  librespot: Path.expand("../_build/librespot/0.8.0-host/bin/librespot", __DIR__),
  spotify_meta: Path.expand("../_build/librespot/0.8.0-host/bin/spotify-meta", __DIR__)

# There's no battery or VintageNet on the host; show a sample status so
# the title bar can be worked on.
config :nerves_phone, :device_status, %{
  battery: %{level: 76, charging: false},
  network: %{kind: :wifi, internet: true, bars: 3}
}

# Tests render the UI headless with the CPU raster renderer, against a fake
# Spotify API and without librespot or audio.
if config_env() == :test do
  config :nerves_phone, start_ui: false, start_audio: false, start_backend: false
  config :nerves_phone, music_backend: NervesPhone.Music.FakeBackend
  config :emerge, compiled_backends: []
end
