# ygg_ex (vendored)

Native Elixir port of the Yggdrasil 0.5.14 node (ironwood router, `encrypted` sessions, no TUN),
embedded into magnet_sorter through `Ygg.Embedded` (see `Spv.YggSup` in `backend/lib/application.ex`).

- Source: repository `ygg_port`, directory `ygg_ex/`, branch `stage3-embed`, commit `3f673888`
  ("Keep private keys out of inspect output and off other users' eyes").
- Copied: `mix.exs`, `mix.lock`, `.formatter.exs`, `.gitignore`, `config/`, `lib/`, `priv/peers/`,
  `ygg.json.example`. Not copied: `test/`, `scripts/`, `STAGE2_CONTRACTS.md`, Go test binaries.
  Tests, the contract and the `ygg.sh` runner live in `ygg_port`.
- `config/` of a dependency is not applied by Mix; the host sets `config :ygg_ex, autostart: false`
  in `backend/config/config.exs`.
- Do not edit here: change `ygg_port/ygg_ex`, run its tests, then re-copy:

      git -C <ygg_port> archive --prefix=ygg_ex/ <ref>:ygg_ex \
        .formatter.exs .gitignore mix.exs mix.lock config lib priv ygg.json.example \
        | tar -x -C backend/vendor

  and update the commit above.
