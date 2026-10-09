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

# The apps on the home screen, in order. Each is a NervesPhone.App.
config :nerves_phone,
  apps: [
    NervesPhone.Apps.Videos,
    NervesPhone.Apps.Flashcards,
    NervesPhone.Apps.Settings
  ]

# The apps' schedule is in local time (NervesPhone.Schedule).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "#{Mix.target()}.exs"
end
