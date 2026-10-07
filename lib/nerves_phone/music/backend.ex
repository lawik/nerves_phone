defmodule NervesPhone.Music.Backend do
  @moduledoc """
  What the player needs from a music service. The app, its state and its UI
  only talk to this; `NervesPhone.Spotify` is the implementation in use.

  Pick it with `config :nerves_phone, :music_backend, Module` (tests use a
  fake).

  Calls may block on the network: the app makes them from tasks, never from
  the UI or its state processes.

  ## Shuffle

  The player always shuffles and never "smart" shuffles. `play/2` must
  start with plain shuffle on and keep playing when the context runs out
  (repeat), and must never add recommendations. `ensure_shuffle/0` turns
  plain shuffle back on if something else changed it.
  """

  @type uri :: String.t()

  @type playlist :: %{
          id: String.t(),
          uri: uri(),
          name: String.t(),
          owner: String.t(),
          mine: boolean(),
          total: non_neg_integer()
        }

  @type album :: %{
          id: String.t(),
          uri: uri(),
          name: String.t(),
          artists: String.t(),
          year: String.t() | nil,
          total: non_neg_integer()
        }

  @type track :: %{
          id: String.t(),
          uri: uri(),
          name: String.t(),
          artists: String.t(),
          album: String.t(),
          album_uri: uri() | nil,
          duration_ms: non_neg_integer(),
          image_url: String.t() | nil
        }

  @typedoc "A page of tracks; `next` is the offset of the next page, or nil."
  @type page :: %{items: [track()], next: non_neg_integer() | nil, total: non_neg_integer()}

  @type playback :: %{
          context_uri: uri() | nil,
          track: track() | nil,
          is_playing: boolean(),
          progress_ms: non_neg_integer(),
          shuffle: boolean(),
          smart_shuffle: boolean()
        }

  @typedoc "Where `play/2` starts in the context."
  @type start :: {:random, total :: non_neg_integer()} | {:track, uri()}

  @doc "A short name, used for its cache directory (e.g. \"spotify\")."
  @callback name() :: String.t()

  @doc "Processes the backend needs, started before the app's state."
  @callback children() :: [Supervisor.child_spec() | module() | {module(), term()}]

  @doc "The FIFO the backend's player writes 44.1 kHz stereo S16 PCM to."
  @callback audio_fifo() :: Path.t()

  @doc "nil when ready, or what the user has to do first (shown on screen)."
  @callback setup_hint() :: String.t() | nil

  @callback playlists() :: {:ok, [playlist()]} | {:error, term()}

  @doc "A page of a playlist's or album's tracks. `{:error, :not_listable}` when the service won't list them."
  @callback tracks(:playlist | :album, id :: String.t(), offset :: non_neg_integer()) ::
              {:ok, page()} | {:error, term()}

  @callback search(query :: String.t()) ::
              {:ok, %{tracks: [track()], albums: [album()], playlists: [playlist()]}}
              | {:error, term()}

  @doc "Whether the local player is reachable, and what it's playing."
  @callback playback() ::
              {:ok, %{device_ready: boolean(), playback: playback() | nil}} | {:error, term()}

  @callback play(context_uri :: uri(), start()) :: :ok | {:error, term()}
  @callback ensure_shuffle() :: :ok | {:error, term()}
  @callback pause() :: :ok | {:error, term()}
  @callback resume() :: :ok | {:error, term()}
  @callback next() :: :ok | {:error, term()}
  @callback previous() :: :ok | {:error, term()}

  @doc "The configured backend."
  def impl, do: Application.get_env(:nerves_phone, :music_backend, NervesPhone.Spotify)
end
