defmodule YggPF.WebPeersTest do
  @moduledoc """
  Web scrape: recursive all-region walk, TCP/TLS only, 2-hour cache and random
  bootstrap selection (spec sections 36-39, 53, 60).
  """

  use ExUnit.Case, async: false

  alias YggPF.{Const, WebPeers}

  # Shaped like a real yggdrasil-network/public-peers markdown file, with the
  # non-TCP/TLS schemes that must now be rejected.
  @markdown """
  # Peers

  ## Germany

  * `tls://ygg1.mk16.de:1338?key=0000000087ee9949`
    220:f022:cd6c:22a9:5285:79e2:2e19:b66a

  * `tcp://ygg1.mk16.de:1337`
    220:f022:cd6c:22a9:5285:79e2:2e19:b66a

  ## Sweden

  * `tls://yggpeer.tilde.green:59454`
    21e:aabf:6a83:d711:db93:8d3d:6131:ba4

  ## Russia

  * `tcp://yggdrasil.su:62486`,
    218:71e5:78e4:8989:b71:db7f:7bf1:f1e1

  ## Rejected schemes

  * `quic://quic.example:9001`
  * `ws://ws.example:80`
  * `wss://wss.example:443`
  * `socks://socks.example:1080`
  * `sockstls://sockstls.example:1080`

  Some prose mentioning http://example.com which is not a peer.
  """

  setup do
    WebPeers.create_table()
    WebPeers.clear_cache()
    on_exit(&WebPeers.clear_cache/0)
    :ok
  end

  describe "scheme restriction: TCP and TLS only" do
    test "accepts tcp and tls" do
      assert WebPeers.valid_uri?("tcp://host.example:1234")
      assert WebPeers.valid_uri?("tls://host.example:1234")
      assert WebPeers.schemes() == ["tcp", "tls"]
    end

    test "rejects every other scheme" do
      for s <- ~w(quic ws wss socks sockstls http https) do
        refute WebPeers.valid_uri?("#{s}://host.example:1234"), "#{s} must be rejected"
      end
    end

    test "sockstls:// is not silently matched as tls://" do
      # The substring "tls://" appears inside "sockstls://" at offset 5. A naive
      # pattern readmits exactly the scheme we are excluding.
      uris = WebPeers.parse_uris("sockstls://sockstls.example:1080")
      assert uris == []
    end

    test "only tcp/tls survive a mixed document" do
      uris = WebPeers.parse_uris(@markdown)

      assert "tls://ygg1.mk16.de:1338?key=0000000087ee9949" in uris
      assert "tcp://ygg1.mk16.de:1337" in uris
      assert "tls://yggpeer.tilde.green:59454" in uris
      assert "tcp://yggdrasil.su:62486" in uris

      for bad <- ~w(quic:// ws:// wss:// socks:// sockstls:// http://) do
        refute Enum.any?(uris, &String.contains?(&1, bad)), "#{bad} leaked through"
      end
    end

    test "strips trailing punctuation" do
      uris = WebPeers.parse_uris(@markdown)
      assert "tcp://yggdrasil.su:62486" in uris
      refute "tcp://yggdrasil.su:62486," in uris
    end

    test "deduplicates while preserving order" do
      text = "tcp://a.example:1\ntcp://b.example:2\ntcp://a.example:1\n"
      assert WebPeers.parse_uris(text) == ["tcp://a.example:1", "tcp://b.example:2"]
    end
  end

  describe "recursive all-region walk" do
    # A two-level tree: root -> region dirs -> .md files, plus a root README that
    # must be ignored and a nested sub-directory that must be followed.
    defp tree_http(log \\ nil) do
      fn url ->
        if log, do: send(log, {:fetched, url})

        case url do
          "https://api.github.com/repos/yggdrasil-network/public-peers/contents" ->
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "README.md",
                 "download_url" => "https://raw.example/README.md", "path" => "README.md"},
               %{"type" => "dir", "name" => "europe", "path" => "europe"},
               %{"type" => "dir", "name" => "asia", "path" => "asia"}
             ])}

          "https://api.github.com/repos/yggdrasil-network/public-peers/contents/europe" ->
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "germany.md",
                 "download_url" => "https://raw.example/de.md", "path" => "europe/germany.md"},
               %{"type" => "dir", "name" => "nordics", "path" => "europe/nordics"}
             ])}

          "https://api.github.com/repos/yggdrasil-network/public-peers/contents/europe/nordics" ->
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "sweden.md",
                 "download_url" => "https://raw.example/se.md",
                 "path" => "europe/nordics/sweden.md"}
             ])}

          "https://api.github.com/repos/yggdrasil-network/public-peers/contents/asia" ->
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "japan.md",
                 "download_url" => "https://raw.example/jp.md", "path" => "asia/japan.md"}
             ])}

          "https://raw.example/README.md" ->
            {:ok, "tcp://should-not-be-used.example:1"}

          "https://raw.example/de.md" ->
            {:ok, "* `tls://de.example:1338`\n  220:f022:cd6c:22a9:5285:79e2:2e19:b66a"}

          "https://raw.example/se.md" ->
            {:ok, "* `tcp://se.example:1337`\n  21e:aabf:6a83:d711:db93:8d3d:6131:ba4"}

          "https://raw.example/jp.md" ->
            {:ok, "* `tls://jp.example:443`\n  21a:1111:2222:3333:4444:5555:6666:7777"}
        end
      end
    end

    test "walks every region and nested directory" do
      assert {:ok, peers} = WebPeers.scrape(http: tree_http(), shuffle?: false)
      uris = Enum.map(peers, & &1.uri)

      assert "tls://de.example:1338" in uris
      assert "tcp://se.example:1337" in uris, "nested sub-directory was not followed"
      assert "tls://jp.example:443" in uris, "second region was not walked"
    end

    test "root-level files are skipped so README examples are not treated as peers" do
      assert {:ok, peers} = WebPeers.scrape(http: tree_http(), shuffle?: false)
      refute Enum.any?(peers, &String.contains?(&1.uri, "should-not-be-used"))
    end

    test "a single region can still be requested" do
      parent = self()
      assert {:ok, _} = WebPeers.scrape(http: tree_http(parent), region: "asia", shuffle?: false)

      urls = collect_urls()
      assert Enum.any?(urls, &String.ends_with?(&1, "/contents/asia"))
      refute Enum.any?(urls, &String.ends_with?(&1, "/contents/europe"))
    end

    defp collect_urls do
      receive do
        {:fetched, u} -> [u | collect_urls()]
      after
        0 -> []
      end
    end

    test "a GitHub API error surfaces" do
      http = fn _ -> {:ok, Jason.encode!(%{"message" => "API rate limit exceeded"})} end
      assert {:error, {:github_api, "API rate limit exceeded"}} = WebPeers.scrape(http: http)
    end

    test "an empty repository is an error, not an empty success" do
      http = fn _ -> {:ok, Jason.encode!([])} end
      assert {:error, :no_peer_files} = WebPeers.scrape(http: http)
    end

    test "one unreachable file does not abort the walk" do
      http = fn
        "https://api.github.com" <> _ = u ->
          if String.ends_with?(u, "/contents") do
            {:ok, Jason.encode!([%{"type" => "dir", "name" => "eu", "path" => "eu"}])}
          else
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "a.md",
                 "download_url" => "https://raw.example/bad.md", "path" => "eu/a.md"},
               %{"type" => "file", "name" => "b.md",
                 "download_url" => "https://raw.example/good.md", "path" => "eu/b.md"}
             ])}
          end

        "https://raw.example/bad.md" -> {:error, :timeout}
        "https://raw.example/good.md" -> {:ok, @markdown}
      end

      assert {:ok, peers} = WebPeers.scrape(http: http, shuffle?: false)
      assert peers != []
    end
  end

  describe "two-hour cache" do
    defp one_peer_http do
      fn
        "https://api.github.com" <> rest ->
          if String.ends_with?(rest, "/contents") do
            {:ok, Jason.encode!([%{"type" => "dir", "name" => "eu", "path" => "eu"}])}
          else
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "a.md",
                 "download_url" => "https://raw.example/a.md", "path" => "eu/a.md"}
             ])}
          end

        "https://raw.example/a.md" ->
          {:ok, @markdown}
      end
    end

    test "TTL is two hours" do
      assert Const.web_cache_ttl_ms() == 2 * 60 * 60 * 1000
    end

    test "a second call is served from cache without any HTTP" do
      assert {:ok, first} = WebPeers.all_peers(http: one_peer_http(), shuffle?: false)

      exploding = fn url -> flunk("cache miss: unexpected fetch of #{url}") end
      assert {:ok, second} = WebPeers.all_peers(http: exploding, shuffle?: false)

      assert Enum.map(first, & &1.uri) |> Enum.sort() ==
               Enum.map(second, & &1.uri) |> Enum.sort()
    end

    test "force bypasses the cache" do
      assert {:ok, _} = WebPeers.all_peers(http: one_peer_http(), shuffle?: false)

      parent = self()

      counting = fn url ->
        send(parent, :fetched)
        one_peer_http().(url)
      end

      assert {:ok, _} = WebPeers.all_peers(http: counting, force: true, shuffle?: false)
      assert_received :fetched
    end

    test "a failed re-scrape falls back to stale cache rather than leaving no peers" do
      assert {:ok, cached} = WebPeers.all_peers(http: one_peer_http(), shuffle?: false)

      failing = fn _ -> {:error, :nxdomain} end
      assert {:ok, stale} = WebPeers.refresh(http: failing)

      assert Enum.map(stale, & &1.uri) |> Enum.sort() ==
               Enum.map(cached, & &1.uri) |> Enum.sort()
    end

    test "with no cache at all, a failure is reported" do
      WebPeers.clear_cache()
      failing = fn _ -> {:error, :nxdomain} end
      assert {:error, _} = WebPeers.all_peers(http: failing)
    end
  end

  describe "random bootstrap selection" do
    defp many_peers_http(n) do
      body =
        Enum.map_join(1..n, "\n\n", fn i ->
          "* `tls://peer#{i}.example:443`\n  2#{rem(i, 10)}e:aabf:6a83:d711:db93:8d3d:6131:b#{i}"
        end)

      fn
        "https://api.github.com" <> rest ->
          if String.ends_with?(rest, "/contents") do
            {:ok, Jason.encode!([%{"type" => "dir", "name" => "eu", "path" => "eu"}])}
          else
            {:ok,
             Jason.encode!([
               %{"type" => "file", "name" => "a.md",
                 "download_url" => "https://raw.example/a.md", "path" => "eu/a.md"}
             ])}
          end

        "https://raw.example/a.md" ->
          {:ok, body}
      end
    end

    test "default bootstrap count is 16" do
      assert Const.web_bootstrap_peers() == 16
    end

    test "selects exactly 16 from a larger population" do
      assert {:ok, chosen} = WebPeers.bootstrap_set(http: many_peers_http(60))
      assert length(chosen) == 16
      assert Enum.uniq_by(chosen, & &1.uri) == chosen
    end

    test "takes everything when fewer than 16 are known" do
      assert {:ok, chosen} = WebPeers.bootstrap_set(http: many_peers_http(5))
      assert length(chosen) == 5
    end

    test "two draws from the same cache differ - selection is random, not the first N" do
      assert {:ok, a} = WebPeers.bootstrap_set(http: many_peers_http(60))
      assert {:ok, b} = WebPeers.bootstrap_set(http: fn _ -> flunk("should be cached") end)

      # 16 of 60 twice: identical sets are vanishingly unlikely.
      refute Enum.map(a, & &1.uri) == Enum.map(b, & &1.uri)
    end

    test "the cache holds the whole population, not just the chosen 16" do
      assert {:ok, _} = WebPeers.bootstrap_set(http: many_peers_http(60))
      assert {:ok, all} = WebPeers.all_peers(http: fn _ -> flunk("should be cached") end)
      assert length(all) == 60
    end

    test "count is overridable" do
      assert {:ok, chosen} = WebPeers.bootstrap_set(http: many_peers_http(60), count: 3)
      assert length(chosen) == 3
    end
  end

  describe "identity grouping and priority" do
    test "two URIs of the same node collapse to one" do
      peers = WebPeers.select(@markdown, :all, shuffle?: false)
      identities = Enum.map(peers, & &1.identity)
      assert identities == Enum.uniq(identities)
    end

    test "web-scraped peers are low priority (INV-019)" do
      [peer | _] = WebPeers.select(@markdown, 1, shuffle?: false)
      assert peer.source == :web_scrape
      assert WebPeers.priority(:web_scrape) > WebPeers.priority(:scan)
    end

    test "validated scan relays outrank and replace web-scraped peers (INV-020)" do
      identity = "220:f022:cd6c:22a9:5285:79e2:2e19:b66a"
      scanned = WebPeers.scan_relay("tls://direct.example:443", identity)

      scraped = %{
        uri: "tls://ygg1.mk16.de:1338",
        identity: identity,
        source: :web_scrape,
        priority: WebPeers.priority(:web_scrape)
      }

      assert [only] = WebPeers.merged([scraped, scanned])
      assert only.source == :scan
      assert only.uri == "tls://direct.example:443"
    end

    test "manual peers are low priority but outrank web scrape" do
      [m] = WebPeers.manual(["tcp://manual.example:1234"])
      assert m.source == :manual
      assert WebPeers.priority(:scan) < m.priority
      assert m.priority < WebPeers.priority(:web_scrape)
    end

    test "manual rejects non-tcp/tls too" do
      assert WebPeers.manual(["quic://q.example:1", "tcp://ok.example:1"]) |> length() == 1
    end
  end
end
