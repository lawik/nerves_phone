defmodule NervesPhone.State.Downloads do
  @moduledoc """
  The downloads in progress, for the title bar: how many there are, and
  how far the oldest has come. Mirrors `NervesPhone.Downloads`.
  """

  use Solve.Controller, events: []

  @impl Solve.Controller
  def init(_params, _dependencies) do
    :ok = NervesPhone.Downloads.subscribe()
    %{count: 0, percent: nil}
  end

  def handle_info({NervesPhone.Downloads, summary}, _state), do: summary
  def handle_info(_message, state), do: state
end
