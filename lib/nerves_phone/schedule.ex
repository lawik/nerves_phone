defmodule NervesPhone.Schedule do
  @moduledoc """
  When each app can be used, kept in `state_dir/schedule.json` and
  managed from phone_remote (or a remote shell).

      {
        "timezone": "Europe/Stockholm",
        "apps": {
          "NervesPhone.Apps.Videos": [
            {"weeks": "every", "days": ["sat", "sun"], "from": "08:00", "to": "18:00"},
            {"weeks": "every", "days": ["mon", "tue", "wed", "thu", "fri"], "from": "16:00", "to": "18:30"}
          ]
        }
      }

  An app that isn't in `"apps"` can always be used. One that is can be
  used while any of its windows is open, and never if it has none. A
  window is:

    * `"weeks"` - `"every"`, or `"odd"` or `"even"` ISO week numbers
      (for every other week)
    * `"days"` - the days it opens on: `"mon"` to `"sun"`
    * `"from"`, `"to"` - `"HH:MM"`, in the schedule's time zone. A `"to"`
      before `"from"` runs past midnight into the next day (the week and
      day are the ones it opens on); `"24:00"` is the end of the day.

  Times are local to `"timezone"` (`"Etc/UTC"` by default), so daylight
  saving is followed. The phone's clock is set from the network, so the
  schedule can be off before it's been online.

  `NervesPhone.State.Schedule` applies it: apps outside their windows are
  left off the home screen, and closed if they're open.
  """

  @days ~w(mon tue wed thu fri sat sun)
  @weeks ~w(every odd even)

  @typedoc "When an app's open; see the moduledoc."
  @type window :: %{String.t() => String.t() | [String.t()]}

  @type t :: %{String.t() => String.t() | %{String.t() => [window()]}}

  @doc "The schedule, or the empty one (everything always) if there's none."
  @spec get() :: t()
  def get do
    with {:ok, json} <- File.read(path()),
         {:ok, schedule} <- JSON.decode(json),
         {:ok, schedule} <- validate(schedule) do
      schedule
    else
      _none -> empty()
    end
  end

  @doc "No limits: every app, always."
  @spec empty() :: t()
  def empty, do: %{"timezone" => "Etc/UTC", "apps" => %{}}

  @doc """
  Replaces the schedule, applying it right away. Apps are named by
  module, as `id/1` gives them.
  """
  @spec put(map()) :: {:ok, t()} | {:error, String.t()}
  def put(schedule) do
    with {:ok, schedule} <- validate(schedule),
         :ok <- save(schedule) do
      Solve.dispatch(NervesPhone.State, :schedule, :changed, schedule)
      {:ok, schedule}
    end
  end

  @doc "The apps that can be scheduled, as `%{id: ..., name: ...}`."
  @spec apps() :: [%{id: String.t(), name: String.t()}]
  def apps, do: for(app <- NervesPhone.App.all(), do: %{id: id(app), name: app.name()})

  @doc "How an app is named in the schedule."
  @spec id(module()) :: String.t()
  def id(app), do: inspect(app)

  @doc "Whether `app` can be used at `now` (a UTC `DateTime`)."
  @spec available?(t(), module(), DateTime.t()) :: boolean()
  def available?(schedule, app, now \\ DateTime.utc_now()) do
    case Map.fetch(schedule["apps"], id(app)) do
      :error -> true
      {:ok, windows} -> Enum.any?(windows, &open?(&1, local(schedule, now)))
    end
  end

  @doc "The apps (of `NervesPhone.App.all/0`) that can be used at `now`."
  @spec available(t(), DateTime.t()) :: [module()]
  def available(schedule, now \\ DateTime.utc_now()),
    do: Enum.filter(NervesPhone.App.all(), &available?(schedule, &1, now))

  # A window is open on its own day from `from`, and, when it runs past
  # midnight, on the next day until `to`.
  defp open?(window, local) do
    from = minutes(window["from"])
    to = minutes(window["to"])
    now = local.hour * 60 + local.minute
    yesterday = DateTime.add(local, -1, :day)

    if from < to do
      on?(window, local) and now >= from and now < to
    else
      (on?(window, local) and now >= from) or (on?(window, yesterday) and now < to)
    end
  end

  defp on?(window, local) do
    day = Enum.at(@days, Date.day_of_week(local) - 1)
    {_year, week} = :calendar.iso_week_number(Date.to_erl(local))

    day in window["days"] and
      case window["weeks"] do
        "every" -> true
        "odd" -> rem(week, 2) == 1
        "even" -> rem(week, 2) == 0
      end
  end

  defp local(schedule, now) do
    case DateTime.shift_zone(now, schedule["timezone"]) do
      {:ok, local} -> local
      {:error, _reason} -> now
    end
  end

  defp minutes(<<h::binary-2, ":", m::binary-2>>),
    do: String.to_integer(h) * 60 + String.to_integer(m)

  @doc """
  Checks a schedule (as decoded from JSON), filling in what's left out.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(%{} = schedule) do
    timezone = schedule["timezone"] || "Etc/UTC"

    with :ok <- check_timezone(timezone),
         {:ok, apps} <- validate_apps(schedule["apps"] || %{}) do
      {:ok, %{"timezone" => timezone, "apps" => apps}}
    end
  end

  def validate(_other), do: {:error, "A schedule is a JSON object"}

  defp check_timezone(timezone) when is_binary(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone) do
      {:ok, _local} -> :ok
      {:error, _reason} -> {:error, "Unknown time zone #{inspect(timezone)}"}
    end
  end

  defp check_timezone(timezone), do: {:error, "Unknown time zone #{inspect(timezone)}"}

  defp validate_apps(%{} = apps) do
    Enum.reduce_while(apps, {:ok, %{}}, fn {app, windows}, {:ok, acc} ->
      case validate_windows(windows) do
        {:ok, windows} -> {:cont, {:ok, Map.put(acc, app, windows)}}
        {:error, message} -> {:halt, {:error, "#{app}: #{message}"}}
      end
    end)
  end

  defp validate_apps(_other), do: {:error, "\"apps\" is an object of apps' windows"}

  defp validate_windows(windows) when is_list(windows) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case validate_window(window) do
        {:ok, window} -> {:cont, {:ok, acc ++ [window]}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_windows(_other), do: {:error, "the windows are a list"}

  defp validate_window(%{} = window) do
    weeks = window["weeks"] || "every"
    days = window["days"]

    cond do
      weeks not in @weeks ->
        {:error, "weeks is one of #{Enum.join(@weeks, ", ")}"}

      not is_list(days) or days == [] or not Enum.all?(days, &(&1 in @days)) ->
        {:error, "days are some of #{Enum.join(@days, ", ")}"}

      not time?(window["from"]) or not time?(window["to"]) ->
        {:error, "from and to are times, such as \"07:30\""}

      window["from"] == window["to"] ->
        {:error, "a window can't start and end at the same time"}

      true ->
        # Days in week order, without repeats.
        days = Enum.filter(@days, &(&1 in days))
        {:ok, %{"weeks" => weeks, "days" => days, "from" => window["from"], "to" => window["to"]}}
    end
  end

  defp validate_window(_other), do: {:error, "a window is an object"}

  defp time?(<<h::binary-2, ":", m::binary-2>>) do
    with {h, ""} <- Integer.parse(h), {m, ""} <- Integer.parse(m) do
      (h in 0..23 and m in 0..59) or (h == 24 and m == 0)
    else
      _not_a_number -> false
    end
  end

  defp time?(_other), do: false

  defp save(schedule) do
    File.mkdir_p(Path.dirname(path()))
    tmp = path() <> ".tmp"

    with :ok <- File.write(tmp, JSON.encode!(schedule)),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} -> {:error, "Couldn't save the schedule: #{:file.format_error(reason)}"}
    end
  end

  defp path, do: Path.join(NervesPhone.state_dir(), "schedule.json")
end
