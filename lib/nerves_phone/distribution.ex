defmodule NervesPhone.Distribution do
  @moduledoc """
  Makes the phone an Erlang distribution node, so other nodes can
  connect to it:

      iex --name me@my-laptop.local --cookie <the phone's cookie>
      iex> Node.connect(:"nerves_phone@nerves-6a3a.local")

  On the phone this starts epmd and the node at boot, named
  `nerves_phone@<hostname>.local` (the mDNS name). Retries every few
  seconds if it can't.

  The cookie is kept in `cookie` under `NervesPhone.state_dir/0`, made
  up at random the first time, and shown and changed in Settings ›
  Security. A changed cookie applies at once, to connections made after.
  """

  use GenServer

  require Logger

  @retry_ms 5_000

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The node's name, distributed or not."
  @spec node_name() :: node()
  def node_name, do: :"nerves_phone@#{NervesPhone.DeviceInfo.hostname()}.local"

  @doc "The cookie, made up and saved the first time it's asked for."
  @spec cookie() :: String.t()
  def cookie do
    case File.read(cookie_path()) do
      {:ok, cookie} ->
        String.trim(cookie)

      {:error, _reason} ->
        cookie = random_cookie()
        :ok = save(cookie)
        cookie
    end
  end

  @doc """
  Sets and saves the cookie. A cookie is 1 to 255 printable ASCII
  characters, without spaces.
  """
  @spec put_cookie(String.t()) :: :ok | {:error, String.t()}
  def put_cookie(cookie) do
    with :ok <- validate(cookie), :ok <- save(cookie) do
      if Node.alive?(), do: set_cookie(cookie)
      :ok
    end
  end

  @doc "A new random cookie, saved and set."
  @spec regenerate_cookie() :: :ok | {:error, String.t()}
  def regenerate_cookie, do: put_cookie(random_cookie())

  @doc "Whether the node is up, its name, and the nodes connected to it."
  @spec status() :: %{alive: boolean(), name: node(), nodes: [node()]}
  def status do
    if Node.alive?(),
      do: %{alive: true, name: node(), nodes: Node.list()},
      else: %{alive: false, name: node_name(), nodes: []}
  end

  @doc false
  def validate(cookie) do
    cond do
      cookie == "" -> {:error, "The cookie can't be empty."}
      byte_size(cookie) > 255 -> {:error, "The cookie is at most 255 characters."}
      not String.match?(cookie, ~r/^[!-~]+$/) -> {:error, "Use letters, digits and symbols only."}
      true -> :ok
    end
  end

  # Node.set_cookie/1 only takes an atom. Cookies are set by hand, one
  # at a time, so the atoms this makes stay few.
  defp set_cookie(cookie), do: Node.set_cookie(String.to_atom(cookie))

  defp cookie_path, do: Path.join(NervesPhone.state_dir(), "cookie")

  defp save(cookie) do
    File.mkdir_p!(NervesPhone.state_dir())

    with :ok <- File.write(cookie_path(), cookie),
         :ok <- File.chmod(cookie_path(), 0o600) do
      :ok
    else
      {:error, reason} -> {:error, "Couldn't save the cookie: #{:file.format_error(reason)}"}
    end
  end

  # 32 random letters and digits.
  defp random_cookie do
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    for <<byte <- :crypto.strong_rand_bytes(32)>>,
      into: "",
      do: <<Enum.at(alphabet, rem(byte, 62))>>
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :start)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:start, state) do
    {_out, _status} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    case Node.start(node_name(), :longnames) do
      {:ok, _pid} ->
        set_cookie(cookie())
        Logger.info("Distribution started as #{node()}")

      {:error, reason} ->
        Logger.warning("Starting distribution failed: #{inspect(reason)}")
        Process.send_after(self(), :start, @retry_ms)
    end

    {:noreply, state}
  end
end
