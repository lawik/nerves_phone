defmodule Mix.Tasks.Flashcards.Decks do
  @shortdoc "Writes the flash card decks that come with the phone into priv/flashcards"
  @moduledoc """
  Writes the decks Flash Cards comes with (`NervesPhone.Apps.Flashcards`)
  as Anki packages in `priv/flashcards`:

      mix flashcards.decks

    * `matte.apkg` - sums for children, in Swedish: plus and minus up to
      10 and up to 20, tiokamrater (the pairs that make 10), and
      multiplikationstabellen, a deck a table
    * `bokstaver.apkg` - the Swedish alphabet, capital and small, with a
      word for each letter

  They're plain Anki packages (the older format, schema 11, which every
  Anki imports), so they can be studied in Anki too. Each note's GUID
  comes from its deck and front, so writing them again keeps the progress
  made on them, and the same decks give the same bytes.
  """

  use Mix.Task

  require Record

  alias Exqlite.Sqlite3

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @dir "priv/flashcards"

  # A deck's cards come in the order given; each is {front, back}.
  @letters [
    {"A", "Apa"},
    {"B", "Bil"},
    {"C", "Citron"},
    {"D", "Docka"},
    {"E", "Elefant"},
    {"F", "Fisk"},
    {"G", "Gris"},
    {"H", "Hus"},
    {"I", "Igelkott"},
    {"J", "Jordgubbe"},
    {"K", "Katt"},
    {"L", "Lejon"},
    {"M", "Mus"},
    {"N", "Noshörning"},
    {"O", "Orm"},
    {"P", "Pingvin"},
    {"Q", "Quiz"},
    {"R", "Räv"},
    {"S", "Sol"},
    {"T", "Tåg"},
    {"U", "Uggla"},
    {"V", "Val"},
    {"W", "Wienerbröd"},
    {"X", "Xylofon"},
    {"Y", "Yxa"},
    {"Z", "Zebra"},
    {"Å", "Åsna"},
    {"Ä", "Älg"},
    {"Ö", "Öga"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    File.mkdir_p!(@dir)

    write("matte.apkg", maths())
    write("bokstaver.apkg", [{"Bokstäver", letters()}])
  end

  defp maths do
    [
      {"Matte::1 Plus upp till 10", for(a <- 1..9, b <- 1..(10 - a), do: sum(a, "+", b, a + b))},
      {"Matte::2 Tiokamrater", for(a <- 0..10, do: {"#{a} + ? = 10", "#{10 - a}"})},
      {"Matte::3 Minus upp till 10", for(a <- 2..10, b <- 1..(a - 1), do: sum(a, "−", b, a - b))},
      {"Matte::4 Plus upp till 20",
       for(a <- 2..10, b <- 1..10, a + b > 10, a + b <= 20, do: sum(a, "+", b, a + b))},
      {"Matte::5 Minus upp till 20",
       for(a <- 11..20, b <- 1..10, a - b <= 10, do: sum(a, "−", b, a - b))}
    ] ++
      for table <- 1..10 do
        {"Matte::6 Multiplikationstabellen::#{table}:ans tabell",
         for(b <- 1..10, do: sum(table, "·", b, table * b))}
      end
  end

  defp sum(a, op, b, answer), do: {"#{a} #{op} #{b}", "#{answer}"}

  # "A a" on the front; the word on the back, its letter in bold.
  defp letters do
    for {letter, word} <- @letters do
      {first, rest} = String.split_at(word, 1)
      {"#{letter} #{String.downcase(letter)}", "<b>#{first}</b>#{rest}"}
    end
  end

  # ---------- The package ----------

  @model_id 1_700_000_000_001

  # The packages' timestamps, fixed so writing them again gives the same
  # bytes (the SOURCE_DATE_EPOCH in config/config.exs).
  @time 1_791_054_690
  @schema """
  CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null,
    scm integer not null, ver integer not null, dty integer not null, usn integer not null,
    ls integer not null, conf text not null, models text not null, decks text not null,
    dconf text not null, tags text not null);
  CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null,
    mod integer not null, usn integer not null, tags text not null, flds text not null,
    sfld integer not null, csum integer not null, flags integer not null, data text not null);
  CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null,
    ord integer not null, mod integer not null, usn integer not null, type integer not null,
    queue integer not null, due integer not null, ivl integer not null, factor integer not null,
    reps integer not null, lapses integer not null, left integer not null, odue integer not null,
    odid integer not null, flags integer not null, data text not null);
  CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null,
    ease integer not null, ivl integer not null, lastIvl integer not null,
    factor integer not null, time integer not null, type integer not null);
  CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
  CREATE INDEX ix_notes_usn on notes (usn);
  CREATE INDEX ix_cards_usn on cards (usn);
  CREATE INDEX ix_revlog_usn on revlog (usn);
  CREATE INDEX ix_cards_nid on cards (nid);
  CREATE INDEX ix_cards_sched on cards (did, queue, due);
  CREATE INDEX ix_revlog_cid on revlog (cid);
  CREATE INDEX ix_notes_csum on notes (csum);
  """

  defp write(file, decks) do
    path = Path.join(@dir, file)
    tmp = Path.join(System.tmp_dir!(), "flashcards-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    db_path = Path.join(tmp, "collection.anki2")
    {:ok, db} = Sqlite3.open(db_path)
    :ok = Sqlite3.execute(db, @schema)

    now = @time

    deck_ids =
      for {{name, _}, i} <- Enum.with_index(decks, 1), into: %{}, do: {name, deck_id(name, i)}

    insert(db, "INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')", [
      now,
      now * 1000,
      now * 1000,
      JSON.encode!(%{"nextPos" => 1, "curModel" => @model_id}),
      JSON.encode!(%{"#{@model_id}" => model(now)}),
      JSON.encode!(
        Map.new([{"Default", 1} | Map.to_list(deck_ids)], fn {name, id} ->
          {"#{id}", deck(id, name, now)}
        end)
      ),
      JSON.encode!(%{"1" => deck_config()})
    ])

    cards = for {name, cards} <- decks, card <- cards, do: {name, card}

    for {{name, {front, back}}, position} <- Enum.with_index(cards, 1) do
      id = now * 1000 + position
      sort_field = front |> String.replace(~r/<[^>]*>/, "")
      <<csum::32, _::binary>> = :crypto.hash(:sha, sort_field)

      insert(db, "INSERT INTO notes VALUES (?, ?, ?, ?, -1, '', ?, ?, ?, 0, '')", [
        id,
        guid(name, front),
        @model_id,
        now,
        front <> "\x1f" <> back,
        sort_field,
        csum
      ])

      insert(
        db,
        "INSERT INTO cards VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')",
        [
          id,
          id,
          deck_ids[name],
          now,
          position
        ]
      )
    end

    :ok = Sqlite3.close(db)

    # The entries carry fixed times.
    {:ok, info} = :file.read_file_info(String.to_charlist(db_path))
    time = @time |> DateTime.from_unix!() |> NaiveDateTime.to_erl()
    info = file_info(info, atime: time, mtime: time, ctime: time)

    entries =
      for {name, data} <- [{"collection.anki2", File.read!(db_path)}, {"media", "{}"}] do
        {String.to_charlist(name), data, file_info(info, size: byte_size(data))}
      end

    {:ok, _} = :zip.create(String.to_charlist(path), entries)

    File.rm_rf!(tmp)
    Mix.shell().info("Wrote #{path} (#{length(cards)} cards)")
  end

  defp insert(db, sql, args) do
    {:ok, statement} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(statement, args)
    :done = Sqlite3.step(db, statement)
    :ok = Sqlite3.release(db, statement)
  end

  defp deck_id(name, i), do: 1_700_000_000_000 + :erlang.phash2(name, 1_000_000) * 100 + i

  defp guid(deck, front) do
    :crypto.hash(:sha256, "nerves_phone:#{deck}:#{front}")
    |> binary_part(0, 8)
    |> Base.url_encode64(padding: false)
  end

  # Anki's Basic note type: Front and Back.
  defp model(now) do
    field = fn name, ord ->
      %{
        "name" => name,
        "ord" => ord,
        "sticky" => false,
        "rtl" => false,
        "font" => "Arial",
        "size" => 20,
        "media" => []
      }
    end

    %{
      "id" => @model_id,
      "name" => "Basic (Nerves Phone)",
      "type" => 0,
      "mod" => now,
      "usn" => -1,
      "sortf" => 0,
      "did" => 1,
      "flds" => [field.("Front", 0), field.("Back", 1)],
      "tmpls" => [
        %{
          "name" => "Card 1",
          "ord" => 0,
          "qfmt" => "{{Front}}",
          "afmt" => "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}",
          "did" => nil,
          "bqfmt" => "",
          "bafmt" => ""
        }
      ],
      "css" =>
        ".card { font-family: arial; font-size: 48px; text-align: center; color: black; background-color: white; }",
      "latexPre" =>
        "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
      "latexPost" => "\\end{document}",
      "req" => [[0, "any", [0]]],
      "tags" => [],
      "vers" => []
    }
  end

  defp deck(id, name, now) do
    %{
      "id" => id,
      "name" => name,
      "mod" => now,
      "usn" => -1,
      "lrnToday" => [0, 0],
      "revToday" => [0, 0],
      "newToday" => [0, 0],
      "timeToday" => [0, 0],
      "collapsed" => false,
      "desc" => "",
      "dyn" => 0,
      "conf" => 1,
      "extendNew" => 10,
      "extendRev" => 50
    }
  end

  defp deck_config do
    %{
      "id" => 1,
      "name" => "Default",
      "mod" => 0,
      "usn" => 0,
      "maxTaken" => 60,
      "autoplay" => true,
      "timer" => 0,
      "replayq" => true,
      "dyn" => false,
      "new" => %{
        "delays" => [1, 10],
        "ints" => [1, 4, 7],
        "initialFactor" => 2500,
        "order" => 1,
        "perDay" => 10,
        "bury" => true
      },
      "lapse" => %{
        "delays" => [10],
        "mult" => 0,
        "minInt" => 1,
        "leechFails" => 8,
        "leechAction" => 0
      },
      "rev" => %{
        "perDay" => 200,
        "ease4" => 1.3,
        "ivlFct" => 1,
        "maxIvl" => 36_500,
        "bury" => true
      }
    }
  end
end
