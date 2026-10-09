defmodule NervesPhone.ScheduleTest do
  use ExUnit.Case, async: true

  alias NervesPhone.Apps.{Settings, Videos}
  alias NervesPhone.Schedule

  defp schedule(windows, timezone \\ "Europe/Stockholm") do
    {:ok, schedule} =
      Schedule.validate(%{
        "timezone" => timezone,
        "apps" => %{"NervesPhone.Apps.Videos" => windows}
      })

    schedule
  end

  # A Stockholm wall-clock time, as UTC.
  defp at(iso) do
    {:ok, naive} = NaiveDateTime.from_iso8601(iso)
    naive |> DateTime.from_naive!("Europe/Stockholm") |> DateTime.shift_zone!("Etc/UTC")
  end

  test "an app that isn't scheduled is always available" do
    s = schedule([])
    assert Schedule.available?(s, Settings, at("2026-10-10T03:00:00"))
    refute Schedule.available?(s, Videos, at("2026-10-10T12:00:00"))
  end

  test "a window is open on its days, from its start until its end, in local time" do
    s = schedule([%{"days" => ["sat", "sun"], "from" => "08:00", "to" => "18:00"}])

    # Saturday 10 October 2026.
    refute Schedule.available?(s, Videos, at("2026-10-10T07:59:00"))
    assert Schedule.available?(s, Videos, at("2026-10-10T08:00:00"))
    assert Schedule.available?(s, Videos, at("2026-10-10T17:59:00"))
    refute Schedule.available?(s, Videos, at("2026-10-10T18:00:00"))
    # Friday.
    refute Schedule.available?(s, Videos, at("2026-10-09T12:00:00"))
  end

  test "follows daylight saving" do
    s =
      schedule([%{"days" => ~w(mon tue wed thu fri sat sun), "from" => "08:00", "to" => "09:00"}])

    # 08:30 local is 06:30 UTC in summer and 07:30 UTC in winter.
    assert Schedule.available?(s, Videos, ~U[2026-07-01 06:30:00Z])
    refute Schedule.available?(s, Videos, ~U[2026-12-01 06:30:00Z])
    assert Schedule.available?(s, Videos, ~U[2026-12-01 07:30:00Z])
  end

  test "a window ending before it starts runs past midnight, from the day it opens" do
    s = schedule([%{"days" => ["fri"], "from" => "22:00", "to" => "01:00"}])

    assert Schedule.available?(s, Videos, at("2026-10-09T23:00:00"))
    assert Schedule.available?(s, Videos, at("2026-10-10T00:30:00"))
    refute Schedule.available?(s, Videos, at("2026-10-10T01:00:00"))
    # Friday early morning belongs to Thursday's night, which isn't open.
    refute Schedule.available?(s, Videos, at("2026-10-09T00:30:00"))
  end

  test "every other week, by ISO week number" do
    s = schedule([%{"weeks" => "odd", "days" => ["sat"], "from" => "00:00", "to" => "24:00"}])

    # 10 October 2026 is in week 41, the 17th in week 42.
    assert Schedule.available?(s, Videos, at("2026-10-10T12:00:00"))
    refute Schedule.available?(s, Videos, at("2026-10-17T12:00:00"))
  end

  test "checks what it's given" do
    assert {:error, "Unknown time zone" <> _} = Schedule.validate(%{"timezone" => "Mars/Base"})

    for window <- [
          %{"days" => [], "from" => "08:00", "to" => "09:00"},
          %{"days" => ["someday"], "from" => "08:00", "to" => "09:00"},
          %{"days" => ["mon"], "from" => "8", "to" => "09:00"},
          %{"days" => ["mon"], "from" => "25:00", "to" => "09:00"},
          %{"days" => ["mon"], "from" => "09:00", "to" => "09:00"},
          %{"weeks" => "third", "days" => ["mon"], "from" => "08:00", "to" => "09:00"}
        ] do
      assert {:error, "Videos: " <> _} =
               Schedule.validate(%{"apps" => %{"Videos" => [window]}}),
             inspect(window)
    end

    assert {:ok, %{"timezone" => "Etc/UTC", "apps" => %{"V" => [window]}}} =
             Schedule.validate(%{
               "apps" => %{
                 "V" => [%{"days" => ["sun", "mon", "sun"], "from" => "08:00", "to" => "09:00"}]
               }
             })

    assert window == %{
             "weeks" => "every",
             "days" => ["mon", "sun"],
             "from" => "08:00",
             "to" => "09:00"
           }
  end
end
