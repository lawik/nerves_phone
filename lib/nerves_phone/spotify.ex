defmodule NervesPhone.Spotify do
  @moduledoc """
  The Spotify backend (`NervesPhone.Music.Backend`).

    * `NervesPhone.Spotify.Auth` keeps a Web API token, from the login made
      with `mix spotify.login`.
    * `NervesPhone.Spotify.API` lists playlists and tracks, searches and
      controls playback.
    * `NervesPhone.Spotify.Librespot` runs librespot, the Spotify Connect
      receiver that streams and decodes, writing PCM to `audio_fifo/0`.
    * `NervesPhone.Spotify.Meta` lists the playlists the Web API won't (ones
      you follow), through librespot's session.

  Playback is controlled through the Web API on the librespot device. It
  runs with autoplay off and librespot has no smart shuffle, so `play/2`
  with shuffle and repeat-context on plays the context shuffled forever.
  """

  @behaviour NervesPhone.Music.Backend

  alias NervesPhone.Spotify.{API, Auth, Librespot, Meta}

  # Right after starting a context the device can briefly refuse commands.
  @retries 3

  @impl true
  def name, do: "spotify"

  @impl true
  def children, do: [Auth, Librespot]

  @impl true
  def audio_fifo, do: Librespot.fifo()

  @impl true
  def setup_hint do
    if Auth.configured?(),
      do: nil,
      else: "Not logged in to Spotify. On your computer, run mix spotify.login, then rebuild."
  end

  @impl true
  def playlists do
    with {:ok, me} <- API.me(), do: API.playlists(me.id)
  end

  # The Web API only lists playlists you own or collaborate on; for the rest
  # spotify-meta gets the whole list in one go.
  @impl true
  def tracks(:playlist, id, offset) do
    case API.playlist_tracks(id, offset) do
      {:error, :not_listable} when offset == 0 -> Meta.playlist_tracks(id)
      result -> result
    end
  end

  def tracks(:album, id, offset), do: API.album_tracks(id, offset)

  @impl true
  def search(query), do: API.search(query)

  @impl true
  def playback do
    with {:ok, device_id} <- device_id(),
         {:ok, player} <- API.player() do
      playback =
        if player && device_id && player.device_id == device_id,
          do: Map.delete(player, :device_id),
          else: nil

      {:ok, %{device_ready: device_id != nil, playback: playback}}
    end
  end

  @impl true
  def play(context_uri, start) do
    offset =
      case start do
        {:track, uri} -> %{uri: uri}
        {:random, total} when total > 0 -> %{position: :rand.uniform(total) - 1}
        {:random, _} -> %{position: 0}
      end

    with_device(fn device ->
      with :ok <- API.play(device, context_uri, offset),
           :ok <- retry(fn -> API.shuffle(device) end),
           :ok <- retry(fn -> API.repeat_context(device) end) do
        :ok
      end
    end)
  end

  @impl true
  def ensure_shuffle, do: with_device(&API.shuffle/1)

  @impl true
  def pause, do: with_device(&API.pause/1)

  @impl true
  def resume, do: with_device(&API.resume/1)

  @impl true
  def next, do: with_device(&API.next/1)

  @impl true
  def previous, do: with_device(&API.previous/1)

  defp with_device(fun) do
    case device_id() do
      {:ok, nil} -> {:error, :no_device}
      {:ok, device} -> forget_device_on_404(device, fun.(device))
      error -> error
    end
  end

  # The device ID is looked up once and kept; a 404 means librespot came
  # back with a new one.
  defp device_id do
    case :persistent_term.get({__MODULE__, :device_id}, nil) do
      nil ->
        with {:ok, id} when id != nil <-
               API.device_id(Auth.config()[:device_name] || "Nerves Phone") do
          :persistent_term.put({__MODULE__, :device_id}, id)
          {:ok, id}
        end

      id ->
        {:ok, id}
    end
  end

  defp forget_device_on_404(_device, {:error, {:http, 404, _}} = error) do
    :persistent_term.erase({__MODULE__, :device_id})
    error
  end

  defp forget_device_on_404(_device, result), do: result

  defp retry(fun, attempts \\ @retries) do
    case fun.() do
      :ok ->
        :ok

      error when attempts <= 1 ->
        error

      _error ->
        Process.sleep(500)
        retry(fun, attempts - 1)
    end
  end
end
