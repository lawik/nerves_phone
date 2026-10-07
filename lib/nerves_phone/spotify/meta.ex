defmodule NervesPhone.Spotify.Meta do
  @moduledoc """
  Lists a playlist's tracks with `spotify-meta` (`native/spotify_meta`), for
  the playlists the Web API won't list in development mode (ones you follow
  but don't own).

  The helper signs in with librespot's cached credentials and reads the
  playlist from Spotify's own metadata service, then the details of each
  track. It returns the whole list at once; the result is cached like any
  other track list, so this only runs when the list is refreshed.
  """

  alias NervesPhone.Spotify.Librespot

  @timeout_ms 120_000

  @spec playlist_tracks(String.t()) :: {:ok, NervesPhone.Music.Backend.page()} | {:error, term()}
  def playlist_tracks(id) do
    args = ["--cache", Librespot.cache_dir(), "playlist", id]

    case MuonTrap.cmd(executable(), args, stderr_to_stdout: false, timeout: @timeout_ms) do
      {json, 0} ->
        %{"tracks" => tracks, "total" => total} = JSON.decode!(json)
        {:ok, %{items: Enum.map(tracks, &track/1), next: nil, total: total}}

      {_output, :timeout} ->
        {:error, :timeout}

      {_output, status} ->
        {:error, {:spotify_meta, status}}
    end
  rescue
    e -> {:error, e}
  end

  defp track(t) do
    %{
      id: t["id"],
      uri: t["uri"],
      name: t["name"],
      artists: t["artists"],
      album: t["album"],
      album_uri: t["album_uri"],
      duration_ms: t["duration_ms"],
      image_url: t["image_url"]
    }
  end

  defp executable do
    Application.get_env(:nerves_phone, :spotify_meta) ||
      Application.app_dir(:nerves_phone, "priv/bin/spotify-meta")
  end
end
