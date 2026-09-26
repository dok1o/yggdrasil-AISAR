defmodule MagnetSorter.Repo do
  use Ecto.Repo,
    otp_app: :magnet_sorter,
    adapter: Ecto.Adapters.SQLite3
  def sql!(query, params \\ []) do
    Ecto.Adapters.SQL.query!(__MODULE__, query, params)
  end
end
defmodule MagnetSorter.Schema do
  alias MagnetSorter.Repo
  @tables """
  CREATE TABLE IF NOT EXISTS files (
    fhash BLOB PRIMARY KEY,
    filesize INTEGER NOT NULL,
    mime SMALLINT
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS torrents (
    infohash BLOB PRIMARY KEY,
    normalized_name TEXT,
    file_count INTEGER DEFAULT 0,
    folder_count INTEGER DEFAULT 0,
    fidxs_bitfield BLOB,
    mime_bitfield BLOB
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS file_torrent_map (
    fhash BLOB NOT NULL,
    infohash BLOB NOT NULL,
    PRIMARY KEY (fhash, infohash)
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS tokens (
    id INTEGER PRIMARY KEY,
    token TEXT UNIQUE NOT NULL
  );
  CREATE TABLE IF NOT EXISTS file_token_map (
    fhash BLOB NOT NULL,
    token_id INTEGER NOT NULL,
    PRIMARY KEY (fhash, token_id)
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS classification (
    subject_type SMALLINT NOT NULL,
    subject_id BLOB NOT NULL,
    bucket SMALLINT NOT NULL,
    PRIMARY KEY (subject_type, subject_id)
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS peers (
    infohash BLOB PRIMARY KEY,
    peers_count INTEGER DEFAULT 0,
    peers_blob BLOB,
    peers_trunc8_hash BLOB,
    last_modified INTEGER DEFAULT (unixepoch())
  ) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS archive_peers (
    infohash BLOB PRIMARY KEY,
    arch_peers_count INTEGER DEFAULT 0,
    arch_peers_blob BLOB,
    arch_peers_trunc8_hash BLOB,
    last_modified INTEGER DEFAULT (unixepoch())
  ) WITHOUT ROWID;
  """
  @indexes """
  CREATE INDEX IF NOT EXISTS idx_ftm_ih ON file_torrent_map(infohash);
  CREATE INDEX IF NOT EXISTS idx_ftkm_tid ON file_token_map(token_id);
  CREATE INDEX IF NOT EXISTS idx_class_bucket ON classification(bucket);
  CREATE INDEX IF NOT EXISTS idx_peers_modified ON peers(last_modified);
  """
  @pragmas """
  PRAGMA page_size = 4096;
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA cache_size = -64000;
  PRAGMA temp_store = MEMORY;
  PRAGMA mmap_size = 268435456;
  PRAGMA secure_delete = OFF;
  """
  def create_db!() do
    run_statements(@pragmas)
    run_statements(@tables)
    run_statements(@indexes)
    :ok
  end
  defp run_statements(sql_const) do
    sql_const
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Repo.sql!/1)
  end
end
defmodule MagnetSorter.Store do
  import TimeSync
  alias MagnetSorter.Repo
  @type_file 1
  @type_token 2
  @bucket_white 1
  @bucket_black 2
  @max_batch_files 300
  @max_batch_torrents 150
  @max_batch_pairs 450
  @max_batch_peers 110
  @max_batch_archive_peers 200
  def load_peers_and_infohashes(limit) do
    sql = """
    SELECT infohash, peers_blob
    FROM peers
    WHERE peers_blob IS NOT NULL AND peers_count > 0
    ORDER BY last_modified DESC
    LIMIT ?1
    """
    Repo.sql!(sql, [limit])
  end
  def get_file(fhash) do
    case Repo.sql!("SELECT fhash, filesize, mime FROM files WHERE fhash = ?1", [fhash]) do
      %{rows: [[fh, sz, m]]} -> %{fhash: fh, filesize: sz, mime: m}
      _ -> nil
    end
  end
  @torrent_columns ~w(infohash normalized_name file_count folder_count fidxs_bitfield mime_bitfield)
  def get_torrent(infohash) do
    sql = "SELECT #{Enum.join(@torrent_columns, ", ")} FROM torrents WHERE infohash = ?1"
    case Repo.sql!(sql, [infohash]) do
      %{rows: [row]} ->
        @torrent_columns
        |> Enum.map(&String.to_atom/1)
        |> Enum.zip(row)
        |> Map.new()
      _ ->
        nil
    end
  end
  def get_files_for_torrent(infohash) do
    %{rows: rows} =
      Repo.sql!("SELECT fhash FROM file_torrent_map WHERE infohash = ?1", [infohash])
    Enum.map(rows, fn [fh] -> fh end)
  end
  def get_torrents_for_file(fhash) do
    %{rows: rows} = Repo.sql!("SELECT infohash FROM file_torrent_map WHERE fhash = ?1", [fhash])
    Enum.map(rows, fn [ih] -> ih end)
  end
  def get_tokens_for_file(fhash) do
    %{rows: rows} =
      Repo.sql!(
        """
        SELECT t.id, t.token
        FROM file_token_map ftm
        JOIN tokens t ON ftm.token_id = t.id
        WHERE ftm.fhash = ?1
        """,
        [fhash]
      )
    Enum.map(rows, fn [id, tok] -> {id, tok} end)
  end
  def get_tokens_for_torrent(infohash) do
    %{rows: rows} =
      Repo.sql!(
        """
        SELECT DISTINCT t.id, t.token
        FROM file_torrent_map ftm
        JOIN file_token_map ftkm ON ftm.fhash = ftkm.fhash
        JOIN tokens t ON ftkm.token_id = t.id
        WHERE ftm.infohash = ?1
        """,
        [infohash]
      )
    Enum.map(rows, fn [id, tok] -> {id, tok} end)
  end
  def fetch_token_ids([]), do: %{}
  def fetch_token_ids(tokens) do
    tokens
    |> Enum.uniq()
    |> Enum.chunk_every(999)
    |> Enum.flat_map(fn batch ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"?#{&1}")
      %{rows: rows} =
        Repo.sql!("SELECT token, id FROM tokens WHERE token IN (#{placeholders})", batch)
      rows
    end)
    |> Map.new(fn [token, id] -> {token, id} end)
  end
  def get_peers_info(infohash) do
    case Repo.sql!(
           """
           SELECT peers_count, peers_trunc8_hash
           FROM peers WHERE infohash = ?1
           """,
           [infohash]
         ) do
      %{rows: [[count, blob_hash]]} ->
        %{
          peers_count: count,
          peers_trunc8_hash: blob_hash
        }
      _ ->
        nil
    end
  end
  def get_peers_blob(infohash) do
    case Repo.sql!("SELECT peers_blob FROM peers WHERE infohash = ?1", [infohash]) do
      %{rows: [[blob]]} -> blob
      _ -> nil
    end
  end
  def get_archive_peers_info(infohash) do
    case Repo.sql!(
           """
           SELECT arch_peers_count, arch_peers_trunc8_hash
           FROM archive_peers WHERE infohash = ?1
           """,
           [infohash]
         ) do
      %{rows: [[count, hash]]} ->
        %{arch_peers_count: count, arch_peers_trunc8_hash: hash}
      _ ->
        nil
    end
  end
  def get_archive_peers_blob(infohash) do
    case Repo.sql!("SELECT arch_peers_blob FROM archive_peers WHERE infohash = ?1", [infohash]) do
      %{rows: [[blob]]} -> blob
      _ -> nil
    end
  end
  def delete_all_peers() do
    Repo.sql!("DELETE FROM peers")
  end
  def get_classification(:file, fhash), do: fetch_class(@type_file, fhash)
  def get_classification(:token, id), do: fetch_class(@type_token, id)
  def get_classified_files(bucket, limit \\ 1000) do
    %{rows: rows} =
      Repo.sql!(
        """
        SELECT subject_id FROM classification
        WHERE subject_type = ?1 AND bucket = ?2
        LIMIT ?3
        """,
        [@type_file, bucket_val(bucket), limit]
      )
    Enum.map(rows, fn [id] -> id end)
  end
  defp fetch_class(type, id) do
    case Repo.sql!(
           "SELECT bucket FROM classification WHERE subject_type = ?1 AND subject_id = ?2",
           [type, id]
         ) do
      %{rows: [[@bucket_white]]} -> :whitelist
      %{rows: [[@bucket_black]]} -> :blacklist
      _ -> nil
    end
  end
  def insert_files_batch([]), do: :ok
  def insert_files_batch(entries) do
    entries
    |> Enum.uniq_by(fn {fhash, _, _} -> fhash end)
    |> Enum.chunk_every(@max_batch_files)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert("INSERT OR IGNORE INTO files (fhash, filesize, mime) VALUES", batch, 3)
      Repo.sql!(sql, params)
    end)
  end
  def insert_torrents_batch([]), do: :ok
  def insert_torrents_batch(entries) do
    entries
    |> Enum.uniq_by(fn {infohash, _, _, _, _, _} -> infohash end)
    |> Enum.chunk_every(@max_batch_torrents)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert(
          "INSERT OR IGNORE INTO torrents (infohash, normalized_name, file_count, folder_count, fidxs_bitfield, mime_bitfield) VALUES",
          batch,
          6
        )
      Repo.sql!(sql, params)
    end)
  end
  def insert_ft_links_batch([]), do: :ok
  def insert_ft_links_batch(entries) do
    entries
    |> Enum.uniq()
    |> Enum.chunk_every(@max_batch_pairs)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert("INSERT OR IGNORE INTO file_torrent_map (fhash, infohash) VALUES", batch, 2)
      Repo.sql!(sql, params)
    end)
  end
  def insert_ftk_links_batch([]), do: :ok
  def insert_ftk_links_batch(entries) do
    entries
    |> Enum.uniq()
    |> Enum.chunk_every(@max_batch_pairs)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert("INSERT OR IGNORE INTO file_token_map (fhash, token_id) VALUES", batch, 2)
      Repo.sql!(sql, params)
    end)
  end
  def insert_tokens_batch([]), do: %{}
  def insert_tokens_batch(tokens) do
    tokens = Enum.uniq(tokens)
    tokens
    |> Enum.chunk_every(999)
    |> Enum.each(fn batch ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"(?#{&1})")
      Repo.sql!("INSERT OR IGNORE INTO tokens (token) VALUES #{placeholders}", batch)
    end)
    fetch_token_ids(tokens)
  end
  def insert_peers_batch([]), do: :ok
  def insert_peers_batch(entries) do
    now = now()
    entries
    |> Enum.reverse()
    |> Enum.uniq_by(fn {infohash, _cnt, _blob, _hash} -> infohash end)
    |> Enum.chunk_every(@max_batch_peers)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert(
          """
          INSERT INTO peers (infohash, peers_count, peers_blob, peers_trunc8_hash, last_modified)
          VALUES
          """,
          Enum.map(batch, fn {ih, cnt, bin, hash} ->
            {ih, cnt, bin, hash, now}
          end),
          5,
          """
          ON CONFLICT (infohash) DO UPDATE SET
            peers_count = excluded.peers_count,
            peers_blob = excluded.peers_blob,
            peers_trunc8_hash = excluded.peers_trunc8_hash,
            last_modified = excluded.last_modified
          """
        )
      Repo.sql!(sql, params)
    end)
  end
  def insert_archive_peers_batch([]), do: :ok
  def insert_archive_peers_batch(entries) do
    now = now()
    entries
    |> Enum.reverse()
    |> Enum.uniq_by(fn {infohash, _, _, _} -> infohash end)
    |> Enum.chunk_every(@max_batch_archive_peers)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert(
          """
          INSERT INTO archive_peers (infohash, arch_peers_count, arch_peers_blob, arch_peers_trunc8_hash, last_modified)
          VALUES
          """,
          Enum.map(batch, fn {ih, count, blob, hash} ->
            {ih, count, blob, hash, now}
          end),
          5,
          """
          ON CONFLICT (infohash) DO UPDATE SET
            arch_peers_count = excluded.arch_peers_count,
            arch_peers_blob = excluded.arch_peers_blob,
            arch_peers_trunc8_hash = excluded.arch_peers_trunc8_hash,
            last_modified = excluded.last_modified
          """
        )
      Repo.sql!(sql, params)
    end)
  end
  def insert_classifications_batch([]), do: :ok
  def insert_classifications_batch(entries) do
    entries
    |> Enum.reverse()
    |> Enum.uniq_by(fn {type, id, _} -> {type, id} end)
    |> Enum.chunk_every(@max_batch_pairs)
    |> Enum.each(fn batch ->
      {sql, params} =
        build_insert(
          "INSERT INTO classification (subject_type, subject_id, bucket) VALUES",
          batch,
          3,
          " ON CONFLICT (subject_type, subject_id) DO UPDATE SET bucket = excluded.bucket"
        )
      Repo.sql!(sql, params)
    end)
  end
  defp bucket_val(:whitelist), do: @bucket_white
  defp bucket_val(:blacklist), do: @bucket_black
  defp build_insert(prefix, rows, cols_per_row, suffix \\ "") do
    placeholders =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {_row, i} ->
        base = i * cols_per_row
        "(#{Enum.map_join(1..cols_per_row, ", ", &"?#{base + &1}")})"
      end)
    params =
      Enum.flat_map(rows, fn
        row when is_tuple(row) -> Tuple.to_list(row)
        row -> row
      end)
    sql = :erlang.iolist_to_binary([prefix, " ", Enum.intersperse(placeholders, ", "), suffix])
    {sql, params}
  end
end