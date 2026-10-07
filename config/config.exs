# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1791054690"

# Spotify login, written by `mix spotify.login`. The refresh token seeds the
# token store on first start; after that the refreshed token is kept in
# the :spotify `state_dir`.
spotify_login = Path.expand("../.spotify.json", __DIR__)

if File.exists?(spotify_login) do
  login = spotify_login |> File.read!() |> JSON.decode!()

  config :nerves_phone, :spotify,
    client_id: login["client_id"],
    refresh_token: login["refresh_token"],
    librespot_credentials: login["librespot_credentials"]
end

# The music service behind the player (see NervesPhone.Music.Backend).
config :nerves_phone, music_backend: NervesPhone.Spotify

# The name the phone shows up as in Spotify Connect.
config :nerves_phone, :spotify, device_name: "Nerves Phone"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "#{Mix.target()}.exs"
end
