defmodule DHTYggScanner do
  import Bitwise
  
  # DHT returns ~8 nodes per query (k-bucket size)
  @nodes_per_query 8
  # Painter injected 3 node_ids into DHT
  @painted_count 3
  # Total DHT routing table entries (rough estimate)
  @total_dht_nodes 10_000_000
  
  defmodule Painter do
    def paint(ipv4, ygg_addr, time_epoch) do
      <<_prefix::7, ones::8, unique::113>> = ygg_addr
      <<chunk1::40, chunk2::40, chunk3::40, _dropped::1>> = <<unique::113>>
      
      [
        {time_epoch, reverse_bits(chunk1, 40), ipv4},
        {time_epoch + 1, reverse_bits(chunk2, 40), ipv4},
        {time_epoch - 1, reverse_bits(chunk3, 40), ipv4}
      ]
    end
    
    defp reverse_bits(n, bits) do
      # Simplified bit reversal
      0..bits-1
      |> Enum.reduce(0, fn i, acc ->
        bit = (n >>> i) &&& 1
        acc ||| (bit <<< (bits - 1 - i))
      end)
    end
  end
  
  # --- Random Sampling Strategy ---
  
  def random_sampling(target_ipv4, time_epoch, max_queries) do
    IO.puts("\n=== Random Sampling ===")
    
    # Simulate painted entries in DHT
    painted_chunks = [
      :rand.uniform(1 <<< 40) - 1,
      :rand.uniform(1 <<< 40) - 1,
      :rand.uniform(1 <<< 40) - 1
    ] |> MapSet.new()
    
    found = random_sample_loop(painted_chunks, target_ipv4, time_epoch, max_queries, MapSet.new(), 0)
    
    IO.puts("Queries made: #{found.queries}")
    IO.puts("Chunks found: #{MapSet.size(found.chunks)}/3")
    IO.puts("Coverage: #{Float.round(found.queries * @nodes_per_query / :math.pow(2, 40) * 100, 6)}%")
    
    found
  end
  
defp random_sample_loop(
       painted,
       target_ipv4,
       epoch,
       max_q,
       found_chunks,
       query_count
     ) do
  if query_count >= max_q or MapSet.size(found_chunks) == 3 do
    %{queries: query_count, chunks: found_chunks}
  else
    probe_chunk = :rand.uniform(1 <<< 40) - 1

    results = simulate_dht_response(probe_chunk, painted, target_ipv4, epoch)

    new_found =
      Enum.reduce(results, found_chunks, fn {chunk, _ipv4}, acc ->
        MapSet.put(acc, chunk)
      end)

    random_sample_loop(
      painted,
      target_ipv4,
      epoch,
      max_q,
      new_found,
      query_count + 1
    )
  end
end
  
  # --- Systematic Walk Strategy ---
  
  def systematic_walk(target_ipv4, time_epoch, region_bits \\ 16) do
    IO.puts("\n=== Systematic Walk (#{region_bits}-bit regions) ===")
    
    # Painted entries
    painted_chunks = [
      :rand.uniform(1 <<< 40) - 1,
      :rand.uniform(1 <<< 40) - 1,
      :rand.uniform(1 <<< 40) - 1
    ] |> MapSet.new()
    
    # Divide 40-bit space into 2^region_bits regions
    regions = 1 <<< region_bits
    region_size = 1 <<< (40 - region_bits)
    
    IO.puts("Total regions: #{regions}")
    IO.puts("Region size: 2^#{40 - region_bits} (#{region_size} values)")
    
    found = systematic_walk_regions(painted_chunks, target_ipv4, time_epoch, 0, regions, region_size, MapSet.new(), 0)
    
    IO.puts("Queries made: #{found.queries}")
    IO.puts("Chunks found: #{MapSet.size(found.chunks)}/3")
    IO.puts("Regions scanned: #{found.queries}")
    
    found
  end
  
defp systematic_walk_regions(
       painted,
       target_ipv4,
       epoch,
       region,
       max_region,
       region_size,
       found_chunks,
       query_count
     ) do
  if region >= max_region or MapSet.size(found_chunks) == 3 do
    %{queries: query_count, chunks: found_chunks}
  else
    # Probe middle of this region
    probe_chunk = region * region_size + div(region_size, 2)

    results = simulate_dht_response(probe_chunk, painted, target_ipv4, epoch)

    new_found =
      Enum.reduce(results, found_chunks, fn {chunk, _ipv4}, acc ->
        MapSet.put(acc, chunk)
      end)

    systematic_walk_regions(
      painted,
      target_ipv4,
      epoch,
      region + 1,
      max_region,
      region_size,
      new_found,
      query_count + 1
    )
  end
end

  
  # --- DHT Simulation ---
  
  defp simulate_dht_response(probe_chunk, painted_chunks, target_ipv4, _epoch) do
    # XOR distance calculation
    distances = painted_chunks
    |> Enum.map(fn chunk -> {bxor(chunk, probe_chunk), chunk} end)
    |> Enum.sort()
    
    # Return closest nodes (k-bucket)
    # In real DHT, we'd get random nodes too, but we only care about painted ones
    distances
    |> Enum.take(@nodes_per_query)
    |> Enum.map(fn {_dist, chunk} -> {chunk, target_ipv4} end)
  end
  
  # --- Hybrid Strategy ---
  
  def adaptive_hybrid(target_ipv4, time_epoch) do
    IO.puts("\n=== Adaptive Hybrid ===")
    IO.puts("Strategy: Random sample first, switch to systematic if needed")
    
    # Try random sampling for limited queries
    result = random_sampling(target_ipv4, time_epoch, 1000)
    
    if MapSet.size(result.chunks) == 3 do
      IO.puts("\n✓ Success with random sampling alone")
      result
    else
      IO.puts("\n⚠ Switching to systematic walk for remaining chunks...")
      # Would continue with systematic
      result
    end
  end
end

# Run simulations
target_ipv4 = {192, 168, 1, 100}
time_epoch = Bitwise.bsr(:os.system_time(:second), 10)  # ~17 minute epochs

DHTYggScanner.random_sampling(target_ipv4, time_epoch, 10_000)
DHTYggScanner.systematic_walk(target_ipv4, time_epoch, 20)
DHTYggScanner.adaptive_hybrid(target_ipv4, time_epoch)
