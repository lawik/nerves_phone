defmodule NervesPhone.SvtPlay.CatalogTest do
  use ExUnit.Case, async: true

  alias NervesPhone.SvtPlay.Catalog

  @now ~U[2026-10-08 20:00:00Z]

  test "an episode that's out and not copy-protected can be downloaded" do
    assert Catalog.available?(
             %{
               "validFrom" => "2026-09-26T12:05:00+02:00",
               "validTo" => "2026-10-26T23:59:59+01:00",
               "restrictions" => %{"drmCopyProtection" => false}
             },
             @now
           )
  end

  # As PAW Patrol: Mighty Pups, Storfilmen, and episodes long gone.
  test "copy-protected, not yet out, and expired things can't" do
    refute Catalog.available?(%{"restrictions" => %{"drmCopyProtection" => true}}, @now)
    refute Catalog.available?(%{"validFrom" => "2026-10-23T02:00:00+02:00"}, @now)
    refute Catalog.available?(%{"validTo" => "2026-10-01T00:00:00+02:00"}, @now)
    refute Catalog.available?(nil, @now)
  end

  test "programmes with episodes have no dates, so they're listed" do
    assert Catalog.available?(%{"__typename" => "KidsTvShow"}, @now)
  end
end
