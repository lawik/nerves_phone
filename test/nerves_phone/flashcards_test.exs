defmodule NervesPhone.FlashcardsTest do
  # Reading Anki packages (both formats), rendering cards, scheduling, and
  # the Flash Cards app. Set UI_SNAPSHOT_DIR to save the screens as PNGs.
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias NervesPhone.Apps.Flashcards
  alias NervesPhone.Flashcards.{Apkg, Html, Library, Progress, Scheduler, Template}

  @app NervesPhone.State

  describe "HTML" do
    test "lines, pictures, sounds and the answer divider" do
      html = """
      <div style="font-size: 40px">A&nbsp;<b>a</b></div><br>
      <img src="apa.jpg"> [sound:a.mp3]
      <hr id=answer>
      <style>.card { color: red }</style>Apa &amp; &#196;lg
      """

      assert Html.blocks(html) == [
               {:text, "A a"},
               {:image, "apa.jpg"},
               {:sound, "a.mp3"},
               :divider,
               {:text, "Apa & Älg"}
             ]
    end

    test "simple MathJax is made plain" do
      assert Html.blocks("\\(3 \\times 4\\)") == [{:text, "3 × 4"}]
      assert Html.blocks("\\[\\frac{1}{2}\\]") == [{:text, "1/2"}]
    end
  end

  describe "templates" do
    @fields %{"Front" => "3 + 4", "Back" => "7", "Extra" => ""}

    test "fields, sections and the front side" do
      front =
        Template.render("{{Front}}{{#Extra}}!{{/Extra}}{{^Extra}}?{{/Extra}}", @fields,
          side: :front
        )

      assert front == "3 + 4?"

      back =
        Template.render("{{FrontSide}}<hr id=answer>{{ Back }}", @fields,
          side: :back,
          front_side: front
        )

      assert back == "3 + 4?<hr id=answer>7"
    end

    test "typed answers show on the back only" do
      assert Template.render("{{Front}}{{type:Back}}", @fields, side: :front) == "3 + 4"
      assert Template.render("{{type:Back}}", @fields, side: :back) == "7"
    end

    test "cloze" do
      fields = %{"Text" => "{{c1::Stockholm}} is in {{c2::Sweden::country}}"}
      render = &Template.render("{{cloze:Text}}", fields, cloze: &1, side: &2)

      assert render.(1, :front) == "[...] is in Sweden"
      assert render.(2, :front) == "Stockholm is in [country]"
      assert render.(2, :back) == "Stockholm is in Sweden"
    end
  end

  describe "scheduler" do
    @tz "Europe/Stockholm"
    @now ~U[2026-10-09 12:00:00Z]

    test "a new card is learnt in steps, then graduates" do
      at = DateTime.to_unix(@now)

      card = Scheduler.answer(nil, :good, @now, @tz)
      assert %{"step" => 1, "due" => due, "first" => "2026-10-09"} = card
      assert due == at + 600
      assert Scheduler.learning?(card)

      card = Scheduler.answer(card, :again, @now, @tz)
      assert card["step"] == 0 and card["due"] == at + 60

      card = Scheduler.answer(card, :good, @now, @tz) |> Scheduler.answer(:good, @now, @tz)
      assert %{"step" => nil, "ivl" => 1} = card
      refute Scheduler.learning?(card)

      # Due at 04:00 local time tomorrow.
      assert card["due"] == DateTime.to_unix(~U[2026-10-10 02:00:00Z])
    end

    test "reviews grow by the ease, and a lapse relearns" do
      card = Scheduler.answer(nil, :easy, @now, @tz)
      assert card["ivl"] == 4

      card = Scheduler.answer(card, :good, @now, @tz)
      assert card["ivl"] == 10

      card = Scheduler.answer(card, :again, @now, @tz)
      assert %{"step" => 0, "ivl" => 5, "lapses" => 1} = card
      assert card["ease"] < 2.5

      card = Scheduler.answer(card, :good, @now, @tz)
      assert %{"step" => nil, "ivl" => 5} = card
    end

    test "days start at 04:00" do
      assert Scheduler.today(~U[2026-10-09 01:30:00Z], @tz) == ~D[2026-10-08]
      assert Scheduler.today(~U[2026-10-09 02:30:00Z], @tz) == ~D[2026-10-09]
    end
  end

  describe "packages" do
    test "the decks that come with the phone" do
      {:ok, package} = Apkg.read(Application.app_dir(:nerves_phone, "priv/flashcards/matte.apkg"))

      decks = package.cards |> Enum.map(& &1.deck) |> Enum.uniq()
      assert "Matte::1 Plus upp till 10" in decks
      assert "Matte::6 Multiplikationstabellen::7:ans tabell" in decks

      card = Enum.find(package.cards, &(&1.front == [{:text, "7 · 8"}]))
      assert card.back == [{:text, "7 · 8"}, :divider, {:text, "56"}]
    end

    @tag :tmp_dir
    test "the older format, with media", %{tmp_dir: dir} do
      path = Path.join(dir, "legacy.apkg")
      legacy_package(path)

      {:ok, package} = Apkg.read(path)

      assert [%{deck: "Djur", front: [{:image, "apa.jpg"}], back: back}] = package.cards
      assert back == [{:image, "apa.jpg"}, :divider, {:text, "Apa"}, {:sound, "apa.mp3"}]
      assert package.media == %{"apa.jpg" => "0", "apa.mp3" => "1", "../evil" => "2"}

      media = Path.join(dir, "media")
      :ok = Apkg.extract_media(path, package.media, media)
      assert File.read!(Path.join(media, "apa.jpg")) == File.read!("test/fixtures/thumb.jpg")
      assert File.ls!(media) |> Enum.sort() == ["apa.jpg", "apa.mp3"]
    end

    @tag :tmp_dir
    test "the current format: compressed, schema 18", %{tmp_dir: dir} do
      path = Path.join(dir, "latest.apkg")
      latest_package(path)

      {:ok, package} = Apkg.read(path)

      assert [card] = package.cards
      assert card.deck == "Språk::Svenska"
      assert card.front == [{:text, "[...] är huvudstaden"}]
      assert card.back == [{:text, "Stockholm är huvudstaden"}, {:text, "Sverige"}]
      assert package.media == %{"karta.png" => "0"}

      :ok = Apkg.extract_media(path, package.media, Path.join(dir, "media"))
      assert File.read!(Path.join(dir, "media/karta.png")) == "png bytes"
    end
  end

  describe "the app" do
    setup do
      :ok = Supervisor.terminate_child(NervesPhone.Supervisor, {NervesPhone.State, @app})
      wait_for(fn -> Task.Supervisor.children(NervesPhone.TaskSupervisor) == [] end)

      root = hd(Application.fetch_env!(:nerves_phone, :flashcards)[:roots])
      File.rm_rf!(root)
      File.mkdir_p!(root)
      legacy_package(Path.join(root, "djur.apkg"))
      File.rm_rf!(Path.join(NervesPhone.state_dir(), "flashcards"))

      :ok = Supervisor.terminate_child(NervesPhone.Supervisor, Progress)
      {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, Progress)
      {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, {NervesPhone.State, @app})
      Solve.dispatch(@app, :flashcards, :opened, nil)
      :ok
    end

    test "lists the decks, with what's new today" do
      wait_for(fn -> not cards().loading end)

      djur = Enum.find(cards().decks, &(&1.name == "Djur"))
      assert %{total: 1, new: 1, due: 0, parent: nil} = djur

      plus = Enum.find(cards().decks, &(&1.name == "1 Plus upp till 10"))
      assert %{parent: "Matte", total: 45, new: 10} = plus

      # The pictures are where the screen may show them.
      assert File.exists?(
               Path.join([Library.cache_dir(), hd(String.split(djur.id, "/")), "media/apa.jpg"])
             )
    end

    test "studying a deck: reveal, answer, and again until it's learnt" do
      wait_for(fn -> not cards().loading end)
      plus = Enum.find(cards().decks, &(&1.name == "1 Plus upp till 10"))

      Solve.dispatch(@app, :flashcards, :study, plus.id)
      wait_for(fn -> cards().page == :study end)

      assert %{left: 10, revealed: false, card: %{front: [{:text, "1 + 1"}]} = first} =
               cards().session

      # Answering before the answer shows does nothing.
      Solve.dispatch(@app, :flashcards, :answer, :good)
      Solve.dispatch(@app, :flashcards, :reveal, nil)
      wait_for(fn -> cards().session.revealed end)
      assert cards().session.card == first

      # Again: back after a few cards.
      Solve.dispatch(@app, :flashcards, :answer, :again)
      wait_for(fn -> cards().session.card != first end)
      assert cards().session.left == 10

      # Easy on everything graduates each card at once.
      for _ <- 1..20, cards().page == :study do
        Solve.dispatch(@app, :flashcards, :reveal, nil)
        Solve.dispatch(@app, :flashcards, :answer, :easy)
        Process.sleep(10)
      end

      wait_for(fn -> cards().page == :done end)
      assert cards().session.studied == 11
      assert %{"ivl" => 4, "reps" => 2} = Progress.all()[first.key]

      # Nothing more today: the ten new ones are used up.
      Solve.dispatch(@app, :flashcards, :decks, nil)
      wait_for(fn -> cards().page == :decks and not cards().loading end)
      assert %{new: 0, due: 0} = Enum.find(cards().decks, &(&1.id == plus.id))
    end

    test "renders the decks, a card and its answer, and done" do
      viewport =
        start_supervised!(
          {NervesPhone.UI,
           backend: :headless, rendering_api: :raster, headless: [mode: :binary, target: self()]}
        )

      assert_receive {:emerge_skia_frame, _frame}, 5_000
      Solve.dispatch(@app, :shell, :open, Flashcards)
      wait_for(fn -> not cards().loading end)
      snapshot(viewport, "flashcards-0-decks")

      djur = Enum.find(cards().decks, &(&1.name == "Djur"))
      Solve.dispatch(@app, :flashcards, :study, djur.id)
      wait_for(fn -> cards().page == :study end)
      snapshot(viewport, "flashcards-1-picture")

      Solve.dispatch(@app, :flashcards, :reveal, nil)
      wait_for(fn -> cards().session.revealed end)
      snapshot(viewport, "flashcards-2-picture-answer")

      Solve.dispatch(@app, :flashcards, :answer, :easy)
      wait_for(fn -> cards().page == :done end)
      snapshot(viewport, "flashcards-3-done")

      Solve.dispatch(@app, :flashcards, :decks, nil)
      wait_for(fn -> cards().page == :decks and not cards().loading end)
      sju = Enum.find(cards().decks, &(&1.name == "7:ans tabell"))
      Solve.dispatch(@app, :flashcards, :study, sju.id)
      wait_for(fn -> cards().page == :study end)
      Solve.dispatch(@app, :flashcards, :reveal, nil)
      wait_for(fn -> cards().session.revealed end)
      snapshot(viewport, "flashcards-4-sum-answer")
    end
  end

  defp cards, do: Solve.subscribe(@app, :flashcards)

  # ---------- Packages ----------

  # A schema 11 package: one Basic note with a picture and a sound, in a
  # deck of its own, and a media name that tries to leave its directory.
  defp legacy_package(path) do
    models = %{
      "100" => %{
        "type" => 0,
        "flds" => [%{"name" => "Front", "ord" => 0}, %{"name" => "Back", "ord" => 1}],
        "tmpls" => [
          %{"ord" => 0, "qfmt" => "{{Front}}", "afmt" => "{{FrontSide}}<hr id=answer>{{Back}}"}
        ]
      }
    }

    db =
      collection("""
      CREATE TABLE col (models text, decks text);
      CREATE TABLE notes (id integer, guid text, mid integer, flds text);
      CREATE TABLE cards (nid integer, ord integer, did integer, type integer, due integer);
      INSERT INTO col VALUES ('#{JSON.encode!(models)}', '{"1": {"name": "Default"}, "7": {"name": "Djur"}}');
      INSERT INTO notes VALUES (1, 'apa-guid', 100, '<img src="apa.jpg">' || char(31) || 'Apa [sound:apa.mp3]');
      INSERT INTO cards VALUES (1, 0, 7, 0, 1);
      """)

    media = JSON.encode!(%{"0" => "apa.jpg", "1" => "apa.mp3", "2" => "../evil"})

    {:ok, _} =
      :zip.create(String.to_charlist(path), [
        {~c"collection.anki2", "Please update Anki"},
        {~c"collection.anki21", db},
        {~c"media", media},
        {~c"0", File.read!("test/fixtures/thumb.jpg")},
        {~c"1", "mp3 bytes"},
        {~c"2", "nope"}
      ])
  end

  # A schema 18 package, zstd-compressed, with protobuf configs and media
  # list: one cloze note with two cards, of which the deck has the first.
  defp latest_package(path) do
    template = proto([{1, "{{cloze:Text}}"}, {2, "{{cloze:Text}}<br>{{Extra}}"}])

    db =
      collection("""
      CREATE TABLE notetypes (id integer, name text, config blob);
      CREATE TABLE fields (ntid integer, ord integer, name text);
      CREATE TABLE templates (ntid integer, ord integer, config blob);
      CREATE TABLE decks (id integer, name text);
      CREATE TABLE notes (id integer, guid text, mid integer, flds text);
      CREATE TABLE cards (nid integer, ord integer, did integer, type integer, due integer);
      INSERT INTO notetypes VALUES (5, 'Cloze', X'#{Base.encode16(proto([{1, 1}, {3, ".card {}"}]))}');
      INSERT INTO fields VALUES (5, 0, 'Text'), (5, 1, 'Extra');
      INSERT INTO templates VALUES (5, 0, X'#{Base.encode16(template)}');
      INSERT INTO decks VALUES (9, 'Språk' || char(31) || 'Svenska');
      INSERT INTO notes VALUES (1, 'cloze-guid', 5,
        '{{c1::Stockholm}} är {{c2::huvudstaden}}' || char(31) || 'Sverige');
      INSERT INTO cards VALUES (1, 0, 9, 0, 1);
      """)

    media = proto([{1, proto([{1, "karta.png"}, {2, 9}])}])

    {:ok, _} =
      :zip.create(String.to_charlist(path), [
        {~c"collection.anki2", "Please update Anki"},
        {~c"collection.anki21b", :zstd.compress(db) |> IO.iodata_to_binary()},
        {~c"media", :zstd.compress(media) |> IO.iodata_to_binary()},
        {~c"0", :zstd.compress("png bytes") |> IO.iodata_to_binary()}
      ])
  end

  defp collection(sql) do
    {:ok, db} = Sqlite3.open(":memory:")
    :ok = Sqlite3.execute(db, sql)
    {:ok, bytes} = Sqlite3.serialize(db)
    :ok = Sqlite3.close(db)
    bytes
  end

  defp proto(fields) do
    for {number, value} <- fields, into: <<>> do
      case value do
        n when is_integer(n) -> varint(Bitwise.bsl(number, 3)) <> varint(n)
        b when is_binary(b) -> varint(Bitwise.bsl(number, 3) + 2) <> varint(byte_size(b)) <> b
      end
    end
  end

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: <<1::1, Bitwise.band(n, 127)::7>> <> varint(Bitwise.bsr(n, 7))

  # ---------- Helpers ----------

  defp snapshot(viewport, name) do
    Process.sleep(300)
    {:ok, png} = EmergeSkia.render_to_png(Emerge.renderer(viewport), timeout: 5_000)
    assert <<0x89, "PNG", _::binary>> = png

    if dir = System.get_env("UI_SNAPSHOT_DIR") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name <> ".png"), png)
    end
  end

  defp wait_for(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(20) && false) end)
    |> Enum.find(fn result -> result || System.monotonic_time(:millisecond) > deadline end)
    |> case do
      false -> flunk("condition not met within #{timeout} ms")
      _ -> :ok
    end
  end
end
