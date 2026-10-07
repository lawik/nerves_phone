defmodule NervesPhone.Spotify.Auth do
  @moduledoc """
  Keeps a fresh Spotify access token.

  Starts from the refresh token baked in from `.spotify.json` (see
  `mix spotify.login`). Spotify may rotate the refresh token on each
  refresh, so the latest one is saved to `state_dir/token.json` and used
  from then on, until a new login changes the baked-in one.
  """

  use GenServer
  require Logger

  @token_url "https://accounts.spotify.com/api/token"
  # Refresh this long before the token expires.
  @margin_s 60

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether a Spotify login is configured."
  def configured?, do: config()[:client_id] != nil and config()[:refresh_token] != nil

  @doc "A valid access token, refreshing it if needed."
  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token, do: GenServer.call(__MODULE__, :access_token, 30_000)

  @doc "Settings from `config :nerves_phone, :spotify`."
  def config, do: Application.get_env(:nerves_phone, :spotify, [])

  @doc "Where tokens, librespot's cache and covers are kept."
  def state_dir, do: config()[:state_dir] || Path.join(System.tmp_dir!(), "nerves_phone_spotify")

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{refresh_token: stored_refresh_token(), access_token: nil, expires_at: 0, last_error: nil}}
  end

  @impl GenServer
  def handle_call(:access_token, _from, state) do
    cond do
      not configured?() ->
        {:reply, {:error, :not_logged_in}, state}

      state.access_token && now() < state.expires_at ->
        {:reply, {:ok, state.access_token}, state}

      true ->
        case refresh(state.refresh_token) do
          {:ok, new} ->
            {:reply, {:ok, new.access_token}, Map.merge(state, new) |> Map.put(:last_error, nil)}

          {:error, reason} ->
            # Offline, this fails on every call; log each new failure once.
            if reason != state.last_error,
              do: Logger.warning("[spotify] token refresh failed: #{inspect(reason)}")

            {:reply, {:error, reason}, %{state | last_error: reason}}
        end
    end
  end

  defp refresh(refresh_token) do
    result =
      Req.post(@token_url,
        form: [
          grant_type: "refresh_token",
          refresh_token: refresh_token,
          client_id: config()[:client_id]
        ],
        retry: :transient
      )

    case result do
      {:ok, %{status: 200, body: body}} ->
        new_refresh = body["refresh_token"] || refresh_token
        if new_refresh != refresh_token, do: store_refresh_token(new_refresh)

        {:ok,
         %{
           refresh_token: new_refresh,
           access_token: body["access_token"],
           expires_at: now() + body["expires_in"] - @margin_s
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body["error_description"] || body["error"]}}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The stored token wins while it was derived from the same baked-in seed.
  defp stored_refresh_token do
    seed = config()[:refresh_token]

    with {:ok, json} <- File.read(token_path()),
         %{"seed" => ^seed, "refresh_token" => token} <- JSON.decode!(json) do
      token
    else
      _ -> seed
    end
  end

  defp store_refresh_token(token) do
    File.mkdir_p!(state_dir())
    json = JSON.encode!(%{seed: config()[:refresh_token], refresh_token: token})
    File.write!(token_path(), json)
    File.chmod!(token_path(), 0o600)
  end

  defp token_path, do: Path.join(state_dir(), "token.json")

  defp now, do: System.os_time(:second)
end
