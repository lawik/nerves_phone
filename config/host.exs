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

# The phone's own files, and fp3_extras's, kept in the project.
config :nerves_phone, state_dir: Path.expand("../tmp/phone", __DIR__)
config :fp3_extras, state_dir: Path.expand("../tmp/phone", __DIR__)

# fp3_extras brings ex_audio and ex_remoteproc along; there's no ADSP to
# kick here.
config :ex_remoteproc, start: []

# There's no battery on the host; show a sample one so the title bar can be
# worked on. The network is NervesPhone.Net's in-memory stand-in.
config :nerves_phone, :device_status, %{battery: %{level: 76, charging: false}}

# Videos looks for files here on the host (/data on the phone).
config :nerves_phone, :videos, roots: [Path.expand("../tmp/videos", __DIR__)]

# Flash Cards looks for decks here on the host (/data/flashcards on the
# phone).
config :nerves_phone, :flashcards, roots: [Path.expand("../tmp/flashcards", __DIR__)]

# The window never dims or goes dark unless that's set in Settings.
config :nerves_phone, :display, dim_after_ms: nil, off_after_ms: nil

# Tests render the UI headless with the CPU raster renderer, and keep their
# files apart.
if config_env() == :test do
  config :nerves_phone, start_ui: false
  config :nerves_phone, state_dir: Path.expand("../tmp/test", __DIR__)
  config :fp3_extras, state_dir: Path.expand("../tmp/test", __DIR__)
  config :nerves_phone, :videos, roots: [Path.expand("../tmp/test/videos", __DIR__)]
  # Queued things wait rather than download.
  config :nerves_phone, :download_queue, run: false

  config :nerves_phone, :flashcards,
    roots: [Path.expand("../tmp/test/decks", __DIR__)],
    sound: nil

  config :emerge, compiled_backends: []
end
