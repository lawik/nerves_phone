defmodule Mix.Tasks.Spotify.Login do
  @shortdoc "Logs in to Spotify and saves a refresh token to .spotify.json"
  @moduledoc """
  Logs in to Spotify in your browser and saves the result to `.spotify.json`.

      mix spotify.login --client-id YOUR_CLIENT_ID

  It logs in twice, both in your browser: once for the Web API with your
  app's client ID, and once for librespot with librespot's own (Spotify
  Connect only accepts credentials from that). Add `--librespot-only` to
  redo just the second step and keep the saved Web API login.

  The phone has no browser, so you log in once on your computer. The
  firmware (or `iex -S mix` on the host) picks up `.spotify.json` at build
  time. Rebuild after logging in.

  Set up an app at https://developer.spotify.com/dashboard first:

    * Add `http://127.0.0.1:8888/callback` as a redirect URI.
    * Tick "Web API".

  The client ID can also come from `SPOTIFY_CLIENT_ID`. Uses the
  authorization code flow with PKCE, so no client secret is needed.

  `.spotify.json` holds a refresh token and librespot credentials that can
  control your Spotify account. It's gitignored; keep it that way.
  """

  use Mix.Task

  @port 8888
  @redirect_uri "http://127.0.0.1:#{@port}/callback"
  @scopes ~w(
    playlist-read-private
    playlist-read-collaborative
    user-read-playback-state
    user-modify-playback-state
    user-read-private
    streaming
  )

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [client_id: :string, librespot_only: :boolean])

    path = Path.join(File.cwd!(), ".spotify.json")
    {:ok, _} = Application.ensure_all_started(:req)

    login =
      if opts[:librespot_only] do
        case File.read(path) do
          {:ok, json} -> JSON.decode!(json)
          _ -> Mix.raise("No .spotify.json yet: run mix spotify.login --client-id ID first.")
        end
      else
        client_id =
          opts[:client_id] || System.get_env("SPOTIFY_CLIENT_ID") ||
            Mix.raise("Pass --client-id or set SPOTIFY_CLIENT_ID. See `mix help spotify.login`.")

        %{"client_id" => client_id, "refresh_token" => web_api_login(client_id)}
      end

    login = Map.put(login, "librespot_credentials", librespot_login())

    File.write!(path, JSON.encode!(login))
    File.chmod!(path, 0o600)
    Mix.shell().info("Saved #{path}. Rebuild the firmware to use it.")
  end

  # Step 1: a refresh token for the Web API (playlists, playback control).
  defp web_api_login(client_id) do
    verifier = random_string(64)
    state = random_string(16)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    url =
      "https://accounts.spotify.com/authorize?" <>
        URI.encode_query(%{
          client_id: client_id,
          response_type: "code",
          redirect_uri: @redirect_uri,
          code_challenge_method: "S256",
          code_challenge: challenge,
          state: state,
          scope: Enum.join(@scopes, " ")
        })

    {:ok, listener} =
      :gen_tcp.listen(@port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    Mix.shell().info("""
    Step 1 of 2: the Web API. Opening your browser; if it doesn't open, visit:

      #{url}
    """)

    open_browser(url)

    code = await_code(listener, state)
    :gen_tcp.close(listener)

    tokens =
      Req.post!("https://accounts.spotify.com/api/token",
        form: [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @redirect_uri,
          client_id: client_id,
          code_verifier: verifier
        ]
      ).body

    tokens["refresh_token"] || Mix.raise("No refresh token: #{inspect(tokens)}")
  end

  # Step 2: credentials for librespot, from its own OAuth login. Spotify
  # Connect only accepts credentials that came from librespot's client ID,
  # so the Web API token can't be used for this. librespot saves reusable
  # credentials, which the phone's librespot starts from.
  defp librespot_login do
    Mix.Task.run("compile")
    exe = Mix.Tasks.Compile.Librespot.path()
    if Mix.target() != :host, do: Mix.raise("Run this with MIX_TARGET unset (host).")

    cache = Path.join(System.tmp_dir!(), "nerves_phone_login_#{random_string(6)}")
    File.mkdir_p!(cache)
    creds = Path.join(cache, "credentials.json")

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args:
          ~w(--enable-oauth --disable-discovery --backend pipe --device /dev/null) ++
            ["--name", "nerves-phone-login", "--cache", cache]
      ])

    Mix.shell().info("Step 2 of 2: librespot, which streams the audio.")

    try do
      await_librespot(port, creds, System.monotonic_time(:second) + 300)
      creds |> File.read!() |> JSON.decode!()
    after
      with {:os_pid, pid} <- Port.info(port, :os_pid), do: System.cmd("kill", ["#{pid}"])
      File.rm_rf!(cache)
    end
  end

  defp await_librespot(port, creds, deadline) do
    receive do
      {^port, {:data, {_, line}}} ->
        case String.split(line, "Browse to: ", parts: 2) do
          [_, url] ->
            Mix.shell().info("Opening your browser; if it doesn't open, visit:\n\n  #{url}\n")
            open_browser(url)

          _ ->
            :ok
        end

        await_librespot(port, creds, deadline)

      {^port, {:exit_status, status}} ->
        if File.exists?(creds), do: :ok, else: Mix.raise("librespot exited (#{status})")
    after
      500 ->
        cond do
          File.exists?(creds) -> :ok
          System.monotonic_time(:second) > deadline -> Mix.raise("Timed out waiting for login")
          true -> await_librespot(port, creds, deadline)
        end
    end
  end

  # Serves one request on the redirect URI and returns its code.
  defp await_code(listener, state) do
    {:ok, socket} = :gen_tcp.accept(listener, :timer.minutes(5))
    {:ok, request} = :gen_tcp.recv(socket, 0, 10_000)
    [_method, target | _] = String.split(request, " ", parts: 3)
    params = target |> URI.parse() |> Map.get(:query, "") |> Kernel.||("") |> URI.decode_query()

    {result, message} =
      cond do
        params["state"] != state -> {:retry, "Unexpected request."}
        params["error"] -> {{:error, params["error"]}, "Login failed: #{params["error"]}"}
        params["code"] -> {{:ok, params["code"]}, "Logged in. You can close this tab."}
        true -> {:retry, "Waiting for Spotify."}
      end

    body = "<!doctype html><title>nerves_phone</title><p>#{message}</p>"

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body
    )

    :gen_tcp.close(socket)

    case result do
      {:ok, code} -> code
      {:error, reason} -> Mix.raise("Spotify login failed: #{reason}")
      :retry -> await_code(listener, state)
    end
  end

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url], stderr_to_stdout: true)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp random_string(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
