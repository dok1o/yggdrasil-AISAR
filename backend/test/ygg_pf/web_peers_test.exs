defmodule YggPF.WebPeersTest do
  @moduledoc """
  Web-scrape parity with the shell/Python originals, and peer priority
  (spec sections 36-39, 53, 60).
  """

  use ExUnit.Case, async: true

  alias YggPF.WebPeers

  # Shaped like a real yggdrasil-network/public-peers markdown file.
  @markdown """
  # Europe

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

  Some prose mentioning http://example.com which is not a peer.
  """

  describe "parsing (parity with parse_ygg_peers.py)" do
    test "extracts only peer schemes" do
      uris = WebPeers.parse_uris(@markdown)

      assert "tls://ygg1.mk16.de:1338?key=0000000087ee9949" in uris
      assert "tcp://ygg1.mk16.de:1337" in uris
      assert "tls://yggpeer.tilde.green:59454" in uris
      refute Enum.any?(uris, &String.starts_with?(&1, "http://"))
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

    test "accepts every documented scheme" do
      for s <- ~w(tcp tls quic ws wss socks sockstls) do
        assert WebPeers.valid_uri?("#{s}://host.example:1234")
      end
    end

    test "rejects malformed and unknown schemes" do
      refute WebPeers.valid_uri?("http://host.example:80")
      refute WebPeers.valid_uri?("tcp://")
      refute WebPeers.valid_uri?("not a uri")
      refute WebPeers.valid_uri?("")
    end
  end

  describe "identity grouping (parity with the 500-char window)" do
    test "two URIs of the same node collapse to one" do
      uris = WebPeers.parse_uris(@markdown)
      groups = WebPeers.group_by_identity(@markdown, uris)
      identities = Enum.map(groups, &elem(&1, 0))

      assert "220:f022:cd6c:22a9:5285:79e2:2e19:b66a" in identities
      # mk16.de contributed two URIs but only one group
      assert length(identities) == length(Enum.uniq(identities))
    end

    test "one URI per node is selected" do
      peers = WebPeers.select(@markdown, 20, shuffle?: false)
      identities = Enum.map(peers, & &1.identity)

      assert length(identities) == length(Enum.uniq(identities))
    end

    test "limit is honoured" do
      assert length(WebPeers.select(@markdown, 2, shuffle?: false)) == 2
    end

    test "peers with no nearby Ygg address fall back to host identity" do
      text = "tcp://lonely.example:9999\ntcp://other.example:8888"
      peers = WebPeers.select(text, 10, shuffle?: false)

      assert length(peers) == 2
      assert Enum.all?(peers, &is_binary(&1.identity))
    end
  end

  describe "source classification and priority (spec sections 36, 37)" do
    test "web-scraped peers are low priority (INV-019)" do
      [peer | _] = WebPeers.select(@markdown, 1, shuffle?: false)

      assert peer.source == :web_scrape
      assert peer.priority == WebPeers.priority(:web_scrape)
      assert WebPeers.priority(:web_scrape) > WebPeers.priority(:scan)
    end

    test "manual peers are also low priority" do
      [peer] = WebPeers.manual(["tcp://manual.example:1234"])
      assert peer.source == :manual
      assert peer.priority > WebPeers.priority(:scan)
    end

    test "validated scan relays outrank web-scraped peers (INV-020)" do
      scanned = WebPeers.scan_relay("tls://found.example:443", "200:1:2:3:4:5:6:7")
      [scraped | _] = WebPeers.select(@markdown, 1, shuffle?: false)

      [first | _] = WebPeers.merged([scraped, scanned])
      assert first.source == :scan
    end

    test "a scan relay replaces the web-scraped entry for the same identity (spec section 37)" do
      identity = "220:f022:cd6c:22a9:5285:79e2:2e19:b66a"
      scanned = WebPeers.scan_relay("tls://direct.example:443", identity)

      scraped = %{
        uri: "tls://ygg1.mk16.de:1338",
        identity: identity,
        source: :web_scrape,
        priority: WebPeers.priority(:web_scrape)
      }

      merged = WebPeers.merged([scraped, scanned])

      assert length(merged) == 1
      assert hd(merged).source == :scan
      assert hd(merged).uri == "tls://direct.example:443"
    end

    test "merging is stable and deduplicated" do
      peers =
        WebPeers.select(@markdown, 20, shuffle?: false) ++
          WebPeers.manual(["tcp://manual.example:1"])

      merged = WebPeers.merged(peers)
      keys = Enum.map(merged, &(&1.identity || &1.uri))

      assert keys == Enum.uniq(keys)
      assert merged == Enum.sort_by(merged, & &1.priority)
    end

    test "limit applies to the merged list" do
      peers = WebPeers.select(@markdown, 20, shuffle?: false)
      assert length(WebPeers.merged(peers, 1)) == 1
    end
  end

  describe "fetch pipeline with an injected client (spec section 53)" do
    test "walks the GitHub contents listing and concatenates peer files" do
      http = fn
        "https://api.github.com/repos/yggdrasil-network/public-peers/contents/europe" ->
          {:ok, Jason.encode!([%{"download_url" => "https://raw.example/de.md"}])}

        "https://raw.example/de.md" ->
          {:ok, @markdown}
      end

      assert {:ok, peers} = WebPeers.fetch(http: http, shuffle?: false, limit: 3)
      assert length(peers) == 3
      assert Enum.all?(peers, &(&1.source == :web_scrape))
    end

    test "a failing peer file is skipped, not fatal" do
      http = fn
        "https://api.github.com" <> _ ->
          {:ok,
           Jason.encode!([
             %{"download_url" => "https://raw.example/bad.md"},
             %{"download_url" => "https://raw.example/good.md"}
           ])}

        "https://raw.example/bad.md" -> {:error, :timeout}
        "https://raw.example/good.md" -> {:ok, @markdown}
      end

      assert {:ok, peers} = WebPeers.fetch(http: http, shuffle?: false)
      assert peers != []
    end

    test "a GitHub API error surfaces" do
      http = fn _ -> {:ok, Jason.encode!(%{"message" => "Not Found"})} end
      assert {:error, {:github_api, "Not Found"}} = WebPeers.fetch(http: http)
    end

    test "an empty listing is an error, not an empty success" do
      http = fn _ -> {:ok, Jason.encode!([])} end
      assert {:error, :no_peer_files} = WebPeers.fetch(http: http)
    end

    test "transport failure propagates" do
      http = fn _ -> {:error, :nxdomain} end
      assert {:error, :nxdomain} = WebPeers.fetch(http: http)
    end

    test "files that contain no peer URIs yield an empty selection" do
      http = fn
        "https://api.github.com" <> _ ->
          {:ok, Jason.encode!([%{"download_url" => "https://raw.example/empty.md"}])}

        _ ->
          {:ok, "no peers here"}
      end

      assert {:ok, []} = WebPeers.fetch(http: http)
    end
  end
end
