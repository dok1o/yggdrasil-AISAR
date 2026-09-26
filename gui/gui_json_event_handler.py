# gui_json_event_handler.py - JSON codec

from dataclasses import dataclass, field
from datetime import datetime
import json
import socket
import base64

@dataclass
class Event:
    event: str
    metadata: dict = field(default_factory=dict)
    runtime: int = 0

    def to_json(self) -> bytes:
        payload = {
            "event": self.event,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "runtime": self.runtime,
            **self.metadata,
        }
        return json.dumps(payload).encode("utf-8")


class EventFactory:
    @staticmethod
    def gui_start():
        return Event("gui.system.start")

    @staticmethod
    def gui_exit():
        return Event("gui.system.exit")

    #@staticmethod
    # def gui_restart_crawl():
    #     return Event("gui.command.restartcrawl")

    @staticmethod
    def gui_error(message: str):
        return Event("gui.system.error", {"message": message})

    # @staticmethod
    # def gui_settings_change():
    #     return Event("gui.settings.change")

    @staticmethod
    def gui_input_loadmagnets(magnet_list):
        events = []
        for item in magnet_list:
            item = item.strip()
            if item:
                events.append(
                    Event("gui.input.loadmagnets", {"payload": item})
                )
        return events

    @staticmethod
    def gui_input_ping_x(ip_str: str):
        """Validate IPv4 and return plain string payload."""
        try:
            socket.inet_aton(ip_str)  # Validates format & raises OSError if invalid
            return Event("gui.input.ping_x", {"payload": ip_str})
        except OSError:
            raise ValueError(f"Invalid IPv4 address: {ip_str}")
        
    @staticmethod
    def gui_ygg_scrape_peers(region: str = "all", limit: int = 16):
        """
        Request a refresh of web-scraped Yggdrasil peers (spec section 40).

        Carries only the user's intent. Fetching, parsing, validation and
        deduplication all happen backend-side in YggPF.WebPeers (spec section 39).
        """
        region = (region or "all").strip().lower()
        # "all" walks every region; otherwise a single directory name (may contain "-")
        if not region.replace("-", "").isalnum():
            raise ValueError(f"Invalid region: {region!r}")
        if not isinstance(limit, int) or not (1 <= limit <= 200):
            raise ValueError(f"Invalid peer limit: {limit!r}")
        return Event("gui.ygg.scrape_peers", {"region": region, "limit": limit})

    # @staticmethod
    # def gui_debug_lookup_fid(fids):
    #     """fids: list of 40-char hex strings"""
    #     return Event("gui.debug.lookup_fid", metadata={"fids": fids})

    # @staticmethod
    # def gui_debug_lookup_uaddr(uaddrs):
    #     """uaddrs: list of 'IP:port' strings"""
    #     return Event("gui.debug.lookup_uaddr", metadata={"uaddrs": uaddrs})

    # @staticmethod
    # def gui_pf_request_fids(list_type):
    #     """Request fnode FID list from backend HydraLoom state."""
    #     return Event("gui.pf.request_fids", metadata={"list_type": list_type})

    # @staticmethod
    # def gui_pf_detect_own_uaddr():
    #     """Request own external address detection via NATChk."""
    #     return Event("gui.pf.detect_own_uaddr", metadata={})

    # @staticmethod
    # def gui_pf_enable():
    #     return Event("gui.pf.enable", metadata={})

    # @staticmethod
    # def crawl_enable():
    #     return Event("gui.crawl.enable", metadata={})
    
    # @staticmethod
    # def gui_pf_rendezvous_publish():
    #     """Publish local FID derived from top frequent IH."""
    #     return Event("gui.pf.rendezvous_publish", metadata={})

    # @staticmethod
    # def gui_pf_rendezvous_seek(target_fid: str):
    #     """Seek a remote FID via zigzag discovery."""
    #     return Event(
    #         "gui.pf.rendezvous_seek",
    #         metadata={"target_fid": target_fid},
    #     )

    # @staticmethod
    # def gui_pf_file_selftest():
    #     """Run loopback BLAKE3 16-chunk UDP transfer self-test (M2+M3)."""
    #     return Event("gui.pf.file_selftest", metadata={})

    # === Torrent parsing events ===

    # @staticmethod
    # def gui_torrents_parse_paths(job_id: str, paths: list):
    #     """Request backend to parse .torrent files at given paths."""
    #     return Event("gui.torrents.parse_paths", metadata={
    #         "job_id": job_id,
    #         "paths": paths
    #     })

    # @staticmethod
    # def gui_torrents_clear_index():
    #     """Request backend to clear torrent index file."""
    #     return Event("gui.torrents.clear_index", metadata={})

    # # === Search events ===

    # @staticmethod
    # def gui_search(job_id: str, query: str, mode: str, path: str = ""):
    #     """
    #     mode: 'phrase' or 'random'
    #     path: specific directory or empty for default
    #     """
    #     return Event("gui.search", metadata={
    #         "job_id": job_id,
    #         "query": query,
    #         "mode": mode,
    #         "path": path
    #     })

    # @staticmethod
    # def gui_search_tokenize(job_id: str, infohash: str, source: str):
    #     """Request token list for a single torrent (by infohash)."""
    #     return Event("gui.search.tokenize", metadata={
    #         "job_id": job_id,
    #         "infohash": infohash,
    #         "source": source,
    #     })

    # @staticmethod
    # def gui_search_classify_token(token, classification):
    #     """Classify a single token as whitelist/greylist/blacklist."""
    #     return Event("gui.search.classify_token", {
    #         "token": token,
    #         "classification": classification,
    #     })

    # # === Sort events ===
    # @staticmethod
    # def gui_sort_get_random():
    #     return Event("gui.sort.get_random")

    # @staticmethod
    # def gui_sort_search(phrase: str):
    #     return Event("gui.sort.search", {"phrase": phrase})

    # @staticmethod
    # def gui_sort_greylist(words: list):
    #     return Event("gui.sort.greylist", {"words": words})

    # @staticmethod
    # def gui_sort_whitelist(token: str, active: bool):
    #     return Event("gui.sort.whitelist", {"token": token, "active": active})

    # @staticmethod
    # def gui_sort_blacklist_hash(infohash: str):
    #     return Event("gui.sort.blacklist_hash", {"infohash": infohash})

    # @staticmethod
    # def gui_sort_trash(infohash: str):
    #     return Event("gui.sort.trash", {"infohash": infohash})

    # @staticmethod
    # def gui_sort_undo_whitelist(token: str):
    #     return Event("gui.sort.undo_whitelist", {"token": token})

    # @staticmethod
    # def gui_sort_undo_trash(infohash: str):
    #     return Event("gui.sort.undo_trash", {"infohash": infohash})

    # @staticmethod
    # def gui_sort_start_search(query): ...
    # @staticmethod
    # def gui_sort_get_random(count): ...
    # @staticmethod
    # def gui_sort_trash(infohash): ...


class EventParser:
    @staticmethod
    def parse_line(line: str):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return None

        if not isinstance(obj, dict) or "event" not in obj:
            return None

        return Event(
            event=obj["event"],
            metadata=obj.get("metadata", {})
        )
