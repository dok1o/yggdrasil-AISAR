defmodule YggPF.Diag do
  @moduledoc """
  Operator-facing state dump for the SDP layer.

  Prints everything needed to check by hand that what we are painting matches what
  a scanner would look for: our own Ygg address, both 72-bit parts, both affixes,
  both `yid`s for the live cursor, the epoch and how long it has left, and what
  painting has actually managed to do.

  A `yid` here is always shown split as `prefix|affix`, because those two halves
  come from completely different places - the prefix from the epoch and cursor, the
  affix from our address - and when discovery breaks it is almost always one half
  or the other, not both.
  """

  require Logger
  alias YggPF.{Codec, Const, Paint, Self}

  @doc """
  Log the full self/paint state.

  `cursor` is the live cursor; the epoch is read from the clock so a desync between
  this line and the painted prefixes is visible directly.
  """
  @spec log_state(non_neg_integer()) :: :ok
  def log_state(cursor) do
    now = System.os_time(:second)
    epoch = Codec.epoch(now)
    left = Const.epoch_seconds() - rem(now, Const.epoch_seconds())

    Logger.info([
      "\n[YggPF] ================= SELF / PAINT STATE =================\n",
      "[YggPF]  epoch      : #{epoch}  (1-min, #{left}s left)  cursor R=#{cursor}\n",
      identity_lines(cursor, epoch),
      paint_lines(),
      "[YggPF] ======================================================"
    ])

    :ok
  end

  # ------------------------------------------------------------------ #

  defp identity_lines(cursor, epoch) do
    case Self.painter_address() do
      nil ->
        [
          "[YggPF]  ygg addr   : UNAVAILABLE - embedded Yggdrasil node not ready.\n",
          "[YggPF]               Nothing can be painted until it is, so scans will\n",
          "[YggPF]               find nothing of ours no matter how many replies arrive.\n"
        ]

      painter ->
        {:ok, {ip, port}} = Codec.parse_painter_address(painter)
        parts = Codec.split_parts(painter)

        [
          "[YggPF]  ygg addr   : #{:inet.ntoa(ip)}  port=#{port}\n",
          "[YggPF]  painter    : #{hex(painter)}  (#{bit_size(painter)} bits)\n",
          Enum.map(Enum.with_index(parts), &part_lines(&1, cursor, epoch))
        ]
    end
  end

  defp part_lines({part, i}, cursor, epoch) do
    affix = Codec.build_affix(part)
    prefix = Codec.derive_prefix(i, cursor, epoch)
    yid = Codec.build_yid(prefix, affix)

    [
      "[YggPF]  --- part #{i} ---\n",
      "[YggPF]    part#{i}    : #{hex(part)}  (#{bit_size(part)} bits)\n",
      "[YggPF]    affix#{i}   : #{hex(affix)}  (bitrev + xor8 checksum)\n",
      "[YggPF]    prefix#{i}  : #{hex(prefix)}  (epoch #{epoch}, cursor #{cursor})\n",
      "[YggPF]    yid#{i}     : #{hex(yid)}\n",
      "[YggPF]               = #{hex(prefix)}|#{hex(affix)}\n"
    ]
  end

  defp paint_lines do
    unique = Paint.unique_asked()
    recent = Paint.recent()

    [
      "[YggPF]  --- painting ---\n",
      "[YggPF]    unique nodes asked this epoch : #{unique}\n",
      "[YggPF]    nodes on ask cooldown         : #{Paint.cooling()} " <>
        "(#{Const.ask_cooldown_ms()}ms each)\n",
      recent_lines(recent),
      hint(unique)
    ]
  end

  defp recent_lines([]) do
    "[YggPF]    last asked                    : none yet\n"
  end

  defp recent_lines(recent) do
    [
      "[YggPF]    last #{length(recent)} asked:\n"
      | Enum.map(recent, fn {rid, uaddr, ms} ->
          "[YggPF]      #{peer(uaddr)}  id=#{hex(rid)}  #{age(ms)}\n"
        end)
    ]
  end

  # The most common failure is painting nothing at all, which looks identical to
  # "nobody is out there" unless it is called out.
  defp hint(0) do
    "[YggPF]    NOTE: no nodes painted yet this epoch. Scans cannot find us, and\n" <>
      "[YggPF]          a self-sighting is impossible until this is non-zero.\n"
  end

  defp hint(_unique), do: []

  # ------------------------------------------------------------------ #

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp age(ms) do
    case div(System.os_time(:millisecond) - ms, 1000) do
      0 -> "just now"
      s -> "#{s}s ago"
    end
  end

  defp peer(uaddr) do
    PrinterSync.peer(uaddr)
  rescue
    _ -> Base.encode16(uaddr, case: :lower)
  end
end
