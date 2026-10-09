defmodule NervesPhone.App do
  @moduledoc """
  An app on the phone.

  Apps are listed in `config :nerves_phone, apps: [...]` and show on the
  home screen in that order. An app brings its own Solve controllers, which
  join `NervesPhone.State`, and renders into the space between the title
  bar and the bottom bar:

      ┌ title bar: app name ──── network · battery ┐
      │ toolbar (`toolbar/0`, optional)            │
      │ content (`render/0`)                       │
      └ [Back] status (`status/0`)          [Home] ┘

  `toolbar/0`, `render/0`, `status/0` and `back/0` run in the viewport's
  process, so they read their controllers with `Solve.Lookup.solve/2` on
  `NervesPhone.State` and make events with `Solve.Lookup.event/3`. While an
  app isn't on screen, updates from its controllers don't re-render.
  """

  @typedoc "A toolbar button, or a separator between groups of them."
  @type tool ::
          {icon :: atom(), label :: String.t(), event :: term(), active? :: boolean()}
          | :separator

  @doc "The name under its icon and in the title bar."
  @callback name() :: String.t()

  @doc "An icon from `priv/icons`, drawn white on the tile."
  @callback icon() :: atom()

  @doc "The tile's gradient, from top-left to bottom-right."
  @callback tile() :: {{0..255, 0..255, 0..255}, {0..255, 0..255, 0..255}}

  @doc "Solve controller specs (`name:`, `module:`, ...) for `NervesPhone.State`."
  @callback controllers() :: [keyword()]

  @callback toolbar() :: [tool()]
  @callback render() :: term()

  @doc "One line about what the app's doing, for the bottom bar."
  @callback status() :: String.t()

  @doc "The event for Back, or nil to go to the home screen."
  @callback back() :: term() | nil

  @doc "Called in the shell controller when the app is opened."
  @callback opened() :: any()

  @doc """
  Called in the shell controller when the schedule closes the app
  (`NervesPhone.Schedule`), to stop what it's doing, such as playing.
  """
  @callback closed() :: any()

  @doc """
  Whether the app takes the whole screen right now (a playing video, say):
  no title bar, toolbar or bottom bar, so it brings its own way back.
  """
  @callback fullscreen?() :: boolean()

  @optional_callbacks opened: 0, closed: 0, fullscreen?: 0

  @doc "Whether `app` wants the whole screen now."
  def fullscreen?(app), do: function_exported?(app, :fullscreen?, 0) and app.fullscreen?()

  @doc "The configured apps."
  def all, do: Application.get_env(:nerves_phone, :apps, [])

  @doc "The names of an app's controllers."
  def controller_names(app), do: Enum.map(app.controllers(), &Keyword.fetch!(&1, :name))
end
