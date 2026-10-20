defmodule NervesPhone.Home do
  @moduledoc """
  Joins the home cluster: starts `home_base` once the phone is a
  distribution node (`NervesPhone.Distribution`).

  home_base keys its `:pg` groups and node state on `node()`, so it can
  only start after `Node.start/2`, and the release only loads it. Before
  starting it this

    * adds the peers' addresses to the resolver, as the phone can't look
      up other `.local` names,
    * sets the home cluster cookie for each peer, so the phone keeps its
      own cookie (Settings › Security) for everything else,
    * makes the Wi-Fi address the media address that sinks on this phone
      bind and give to sources,
    * raises the kernel's default socket send buffer (`:send_buffer`, 2 MB):
      media sockets get the default, and 208 KB fills up with a camera
      keyframe's packets, sent all at once, which fails the session.

      config :nerves_phone, :home,
        cookie: :home_cluster_cookie,
        interface: "wlan0",
        peers: [{:"nerves_phone@nerves-6a3a.local", "192.168.4.135"}, ...]

  A peer without an address is one the resolver already knows (a name
  like `home@192.168.4.148`). The capabilities and the cluster backend are
  home_base's own config (`config :home_base, ...`); the peers listed here
  are added to a `Home.Cluster.Static` backend.
  """

  use GenServer

  require Logger

  @poll_ms 1_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether home_base is running on this node."
  @spec running?() :: boolean()
  def running?, do: List.keymember?(Application.started_applications(), :home_base, 0)

  @impl GenServer
  def init(_opts) do
    send(self(), :start)
    {:ok, Application.get_env(:nerves_phone, :home, [])}
  end

  @impl GenServer
  def handle_info(:start, config) do
    with true <- Node.alive?(), {:ok, ip} <- address(config) do
      start_home_base(config, ip)
    else
      _ -> Process.send_after(self(), :start, @poll_ms)
    end

    {:noreply, config}
  end

  defp start_home_base(config, ip) do
    peers = Keyword.get(config, :peers, [])
    cookie = Keyword.get(config, :cookie, :home_cluster_cookie)

    for {peer, address} <- peers, peer != node() do
      if address, do: add_host(peer, address)
      :erlang.set_cookie(peer, cookie)
    end

    set_send_buffer(Keyword.get(config, :send_buffer, 2_097_152))

    media = Application.get_env(:home_base, :media, [])
    Application.put_env(:home_base, :media, Keyword.put(media, :ip, ip))
    Application.put_env(:home_base, :device_id, NervesPhone.DeviceInfo.hostname())

    Application.put_env(:home_base, :cluster,
      backend: {Home.Cluster.Static, nodes: Enum.map(peers, &elem(&1, 0))}
    )

    case Application.ensure_all_started(:home_base) do
      {:ok, _apps} -> Logger.info("home_base started on #{node()}, media on #{:inet.ntoa(ip)}")
      {:error, reason} -> Logger.error("Starting home_base failed: #{inspect(reason)}")
    end
  end

  defp set_send_buffer(bytes) do
    case File.write("/proc/sys/net/core/wmem_default", Integer.to_string(bytes)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Couldn't set the send buffer: #{inspect(reason)}")
    end
  end

  defp add_host(peer, address) do
    [_name, host] = peer |> Atom.to_string() |> String.split("@", parts: 2)
    {:ok, ip} = address |> to_charlist() |> :inet.parse_address()
    :inet_db.add_host(ip, [to_charlist(host)])
  end

  defp address(config) do
    interface = config |> Keyword.get(:interface, "wlan0") |> to_charlist()

    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         {_, opts} <- List.keyfind(ifaddrs, interface, 0),
         ip when is_tuple(ip) <-
           Enum.find(Keyword.get_values(opts, :addr), &(tuple_size(&1) == 4)) do
      {:ok, ip}
    else
      _ -> :error
    end
  end
end
