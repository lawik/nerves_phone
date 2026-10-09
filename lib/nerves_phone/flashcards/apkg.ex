defmodule NervesPhone.Flashcards.Apkg do
  @moduledoc """
  Reads Anki deck packages (`.apkg`), as shared on AnkiWeb and exported
  from Anki.

  A package is a zip of a SQLite collection and its media:

    * `collection.anki21b` - the current format: the collection
      zstd-compressed, in Anki's schema 18 (note types, fields, templates
      and decks in tables of their own, with protobuf configs). The
      `media` list is zstd-compressed protobuf, and so are the media files.
    * `collection.anki21` or `collection.anki2` - the older formats,
      schema 11: note types and decks as JSON in the `col` table, and
      `media` a JSON map. Packages in the current format still carry a
      `collection.anki2`, with a single note saying to update Anki, so
      the newest collection there is is the one read.

  Media files are numbered in the zip (`0`, `1`, ...) and the `media`
  list gives their names.

  Each card is rendered with its note type's templates
  (`NervesPhone.Flashcards.Template`) into blocks for the screen
  (`NervesPhone.Flashcards.Html`), front and back.
  """

  alias Exqlite.Sqlite3
  alias NervesPhone.Flashcards.{Html, Protobuf, Template}

  @type card :: %{
          key: String.t(),
          deck: String.t(),
          new_order: integer(),
          front: [Html.block()],
          back: [Html.block()]
        }

  @type t :: %{cards: [card()], media: %{String.t() => String.t()}}

  @collections ~w(collection.anki21b collection.anki21 collection.anki2)

  @zstd_magic <<0x28, 0xB5, 0x2F, 0xFD>>

  @doc """
  Reads a package: its cards, and its media as `name => entry in the zip`.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, zip} <- :zip.zip_open(String.to_charlist(path), [:memory]) do
      try do
        with {:ok, names} <- entries(zip),
             {:ok, name} <- collection(names),
             {:ok, db_bytes} <- get(zip, name),
             {:ok, cards} <- read_collection(maybe_unzstd(db_bytes)) do
          {:ok, %{cards: cards, media: media(zip, names)}}
        end
      after
        :zip.zip_close(zip)
      end
    end
  end

  @doc """
  Writes the package's media files into `dir` under their names (as
  `read/1` listed them), skipping names that aren't plain file names.
  """
  @spec extract_media(Path.t(), %{String.t() => String.t()}, Path.t()) :: :ok | {:error, term()}
  def extract_media(path, media, dir) do
    File.mkdir_p!(dir)

    with {:ok, zip} <- :zip.zip_open(String.to_charlist(path), [:memory]) do
      try do
        for {name, entry} <- media, safe_name?(name) do
          with {:ok, data} <- get(zip, entry) do
            File.write!(Path.join(dir, name), maybe_unzstd(data))
          end
        end

        :ok
      after
        :zip.zip_close(zip)
      end
    end
  end

  @doc "Whether a media name is a plain file name, safe to write in a directory."
  def safe_name?(name) do
    name != "" and name not in [".", ".."] and not String.contains?(name, ["/", "\\", <<0>>])
  end

  # ---------- The zip ----------

  defp entries(zip) do
    case :zip.zip_list_dir(zip) do
      {:ok, list} -> {:ok, for({:zip_file, name, _, _, _, _} <- list, do: to_string(name))}
      error -> error
    end
  end

  defp collection(names) do
    case Enum.find(@collections, &(&1 in names)) do
      nil -> {:error, :no_collection}
      name -> {:ok, name}
    end
  end

  defp get(zip, name) do
    case :zip.zip_get(String.to_charlist(name), zip) do
      {:ok, {_name, data}} -> {:ok, data}
      {:error, reason} -> {:error, {:zip, name, reason}}
    end
  end

  defp maybe_unzstd(<<@zstd_magic, _::binary>> = data),
    do: data |> :zstd.decompress() |> IO.iodata_to_binary()

  defp maybe_unzstd(data), do: data

  # name => zip entry. JSON ({"0": "a.jpg"}) in the older formats, and
  # protobuf (MediaEntries) in the current one, where an entry's place in
  # the list is its name in the zip unless it says otherwise.
  defp media(zip, names) do
    with true <- "media" in names,
         {:ok, data} <- get(zip, "media") do
      data = maybe_unzstd(data)

      case JSON.decode(data) do
        {:ok, %{} = map} ->
          Map.new(map, fn {entry, name} -> {name, entry} end)

        _not_json ->
          data
          |> Protobuf.decode()
          |> Protobuf.all(1)
          |> Enum.with_index()
          |> Map.new(fn {entry, index} ->
            fields = Protobuf.decode(entry)
            zip_name = Protobuf.first(fields, 255)
            {Protobuf.first(fields, 1, ""), to_string(zip_name || index)}
          end)
      end
    else
      _none -> %{}
    end
  end

  # ---------- The collection ----------

  defp read_collection(bytes) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      with :ok <- Sqlite3.deserialize(db, bytes),
           {:ok, notetypes, decks} <- notetypes_and_decks(db),
           {:ok, notes} <- query(db, "SELECT id, guid, mid, flds FROM notes"),
           {:ok, cards} <- query(db, "SELECT nid, ord, did, type, due FROM cards") do
        notes = Map.new(notes, fn [id, guid, mid, flds] -> {id, {guid, mid, flds}} end)

        {:ok,
         for [nid, ord, did, type, due] <- cards,
             {guid, mid, flds} <- List.wrap(notes[nid]),
             notetype = notetypes[mid],
             notetype != nil,
             card = render(notetype, guid, flds, ord),
             card != nil do
           # New cards (type 0) are shown in the order of their due
           # number; others had theirs set by reviews, so after them.
           order = if type == 0, do: due, else: 1_000_000_000 + nid

           Map.merge(card, %{deck: Map.get(decks, did, "Default"), new_order: order})
         end}
      end
    after
      Sqlite3.close(db)
    end
  end

  defp render(notetype, guid, flds, ord) do
    fields = notetype.fields |> Enum.zip(String.split(flds, "\x1f")) |> Map.new()

    {template, cloze} =
      case notetype.kind do
        :cloze -> {hd(notetype.templates), ord + 1}
        :normal -> {Enum.find(notetype.templates, &(&1.ord == ord)), nil}
      end

    if template do
      front = Template.render(template.front, fields, cloze: cloze, side: :front)

      back =
        Template.render(template.back, fields, cloze: cloze, side: :back, front_side: front)

      %{key: "#{guid}:#{ord}", front: Html.blocks(front), back: Html.blocks(back)}
    end
  end

  defp notetypes_and_decks(db) do
    case query(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'notetypes'") do
      {:ok, [_]} -> schema18(db)
      {:ok, []} -> schema11(db)
      error -> error
    end
  end

  # Note types and decks are JSON in the col table.
  defp schema11(db) do
    with {:ok, [[models, decks]]} <- query(db, "SELECT models, decks FROM col") do
      notetypes =
        for {id, model} <- JSON.decode!(models), into: %{} do
          fields = model["flds"] |> Enum.sort_by(& &1["ord"]) |> Enum.map(& &1["name"])

          templates =
            for t <- model["tmpls"], do: %{ord: t["ord"], front: t["qfmt"], back: t["afmt"]}

          kind = if model["type"] == 1, do: :cloze, else: :normal
          {String.to_integer(id), %{kind: kind, fields: fields, templates: templates}}
        end

      decks =
        for {id, deck} <- JSON.decode!(decks),
            into: %{},
            do: {String.to_integer(id), deck["name"]}

      {:ok, notetypes, decks}
    end
  end

  # Note types, their fields and templates, and decks have tables of
  # their own, with protobuf configs (anki/notetypes.proto): a note type's
  # kind is field 1 of its config (1 for cloze), and a template's front
  # and back formats fields 1 and 2 of its.
  defp schema18(db) do
    with {:ok, types} <- query(db, "SELECT id, config FROM notetypes"),
         {:ok, fields} <- query(db, "SELECT ntid, ord, name FROM fields"),
         {:ok, templates} <- query(db, "SELECT ntid, ord, config FROM templates"),
         {:ok, decks} <- query(db, "SELECT id, name FROM decks") do
      fields = Enum.group_by(fields, &hd/1, fn [_, ord, name] -> {ord, name} end)

      templates =
        Enum.group_by(templates, &hd/1, fn [_, ord, config] ->
          config = Protobuf.decode(config)

          %{
            ord: ord,
            front: Protobuf.first(config, 1, ""),
            back: Protobuf.first(config, 2, "")
          }
        end)

      notetypes =
        for [id, config] <- types, into: %{} do
          kind = if Protobuf.first(Protobuf.decode(config), 1, 0) == 1, do: :cloze, else: :normal

          {id,
           %{
             kind: kind,
             fields: fields |> Map.get(id, []) |> Enum.sort() |> Enum.map(&elem(&1, 1)),
             templates: templates |> Map.get(id, []) |> Enum.sort_by(& &1.ord)
           }}
        end

      # Subdecks are separated by \x1f here, and by "::" everywhere else.
      decks = Map.new(decks, fn [id, name] -> {id, String.replace(name, "\x1f", "::")} end)
      {:ok, notetypes, decks}
    end
  end

  defp query(db, sql) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        Sqlite3.fetch_all(db, statement)
      after
        Sqlite3.release(db, statement)
      end
    end
  end
end
