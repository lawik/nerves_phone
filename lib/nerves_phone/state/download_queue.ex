defmodule NervesPhone.State.DownloadQueue do
  @moduledoc """
  The download queue (`NervesPhone.DownloadQueue`), for phone_remote,
  which subscribes to it over distribution. Exposes `items`.
  """

  use Solve.Controller, events: []

  @impl Solve.Controller
  def init(_params, _dependencies) do
    :ok = NervesPhone.DownloadQueue.subscribe()
    %{items: []}
  end

  def handle_info({NervesPhone.DownloadQueue, items}, state), do: %{state | items: items}
  def handle_info(_message, state), do: state
end
