defmodule Spawn do
  require Logger
  def krpc_worker_task(packet, ipv4, port, shard_id) do
    do_spawn(fn ->
      TelemetrySync.nat_chk_telemetry(packet, ipv4, port)
      KRPCWorkerTask.process_dht(packet, ipv4, port, shard_id)
    end)
  end
  def pf_worker_task(pf_txid, frid, opcode, msg, {a, b, c, d}, port) do
    do_spawn(fn ->
      fnodev4 = <<a, b, c, d, port::16>>
      {:insert_one_fnode_with_ip_clamp, {frid, fnodev4}}
      PFBinWorkerTask.handle(pf_txid, {frid, fnodev4}, opcode, msg)
    end)
  end
  def fetch_result_task({ih, info_bin}, start, save_tjf?) do
    do_spawn(fn ->
      ResultTask.process({ih, info_bin}, start, save_tjf?)
    end)
  end
  defp do_spawn(fun) do
    spawn(fn ->
      try do
        fun.()
      rescue
        e ->
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      catch
        kind, reason ->
          Logger.error(Exception.format(kind, reason, __STACKTRACE__))
      end
    end)
  end
end