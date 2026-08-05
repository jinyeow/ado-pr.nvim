# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-05

### Bug Fixes
- Resolve az.cmd on Windows + strip az devops invoke preamble ([375d5de](https://github.com/jinyeow/ado-pr.nvim/commit/375d5de3216e804e3dcd7c80b2ce09ad4f59eb82))
- Read window ids from view.cur_layout, not entry.layout ([4c411db](https://github.com/jinyeow/ado-pr.nvim/commit/4c411db964c769c3635eeb17e7ef4da4e0b2f809))
- Spawn az via cmd.exe /c; accept inline :AdoPrComment text ([d6aa60e](https://github.com/jinyeow/ado-pr.nvim/commit/d6aa60e59493e6a4b651d0a18d851da9cec1685b))
- Left side of a modified file falls back to path ([3d2301a](https://github.com/jinyeow/ado-pr.nvim/commit/3d2301a1d296617bcaddf7c4f996599e235fb6c0))
- Raise on malformed thread response, fix zero-line clamp ([958e38d](https://github.com/jinyeow/ado-pr.nvim/commit/958e38dda3303ff153cfffb36d7a573c80f7604b))
- Resolve diff base from PR target ref ([2ba1a14](https://github.com/jinyeow/ado-pr.nvim/commit/2ba1a145834aa4a6dcb2d3f64791cf11a70a1811))
- Fix active-PR state ordering, retry fetch with warning, strengthen tests ([4ff363f](https://github.com/jinyeow/ado-pr.nvim/commit/4ff363fa3c43b8d8c94f4ceb479f7cb51996df5a))
- Decode JSON null as Lua nil in az_json ([3b4ef38](https://github.com/jinyeow/ado-pr.nvim/commit/3b4ef38bd24845df65ae8130605cf9f39376f205))
- Treat pure-insertion boundary line as unshifted (#31) ([f2b6b49](https://github.com/jinyeow/ado-pr.nvim/commit/f2b6b494470c6dd730212ac23b3fc8fd266c5df8))
- Clamp ]t/[t navigation to buffer bounds (#33) ([7ba66d1](https://github.com/jinyeow/ado-pr.nvim/commit/7ba66d120bd9f828fdddb10bd5a74e9249730a6b))
- Skip follower-pane attach on vim-fugitive fallback (#34) ([365c06e](https://github.com/jinyeow/ado-pr.nvim/commit/365c06ebc94c0f7ecda3ac3ddb158079c0667760))
- Scope pane state and autocmds per Diffview session (#35) ([106863e](https://github.com/jinyeow/ado-pr.nvim/commit/106863ed3f713d33c57fb4060ffc9341f43edcbf))
- Represent git-diff failure explicitly instead of caching as identity mapping (#36) ([9564705](https://github.com/jinyeow/ado-pr.nvim/commit/9564705b1ecc9f2f00cbe34b5f84a51c446a50f9))
- Pair replacement-hunk lines instead of marking them unshowable (#37) ([20129aa](https://github.com/jinyeow/ado-pr.nvim/commit/20129aa916117ef46ca35763cd4e0d5e37483034))
- Re-notify not-showable thread count on refresh, not just on open (#38) ([fdb0f53](https://github.com/jinyeow/ado-pr.nvim/commit/fdb0f531e4c9972931217bc9e989996eee5f8b98))
- Compare clamped landing row, not stale line_start, in jump (#44) ([d563a21](https://github.com/jinyeow/ado-pr.nvim/commit/d563a213d564bca12296e41a8ac80bb73093af42))


### CI
- Add GitHub Actions workflow with tests and stylua lint (#40) ([406a721](https://github.com/jinyeow/ado-pr.nvim/commit/406a7215a7903b030021d8c7a30ab244ffa94f58))


### Documentation
- Add PR-comment-threads spec/design/ADRs, agent-skills config, UI prototype ([a189afb](https://github.com/jinyeow/ado-pr.nvim/commit/a189afb91efa1a27aadbb76aadcdb833730baf16))
- Add specs for PR checkout robustness and per-directory ADO config ([3e5c67b](https://github.com/jinyeow/ado-pr.nvim/commit/3e5c67b62e69ded71228bdda9453fd0873191516))
- Commit left-side-thread-anchoring spec ([a8a030a](https://github.com/jinyeow/ado-pr.nvim/commit/a8a030ae5881f8838a59c8299354792da756de1b))


### Features
- Scaffold ado-pr.nvim MVP (pick/checkout/diff/vote via az; threads TODO) ([1381e42](https://github.com/jinyeow/ado-pr.nvim/commit/1381e424830416bce8cd9163d274ae7ef2ba2cef))
- Map diffview cursor to ADO thread anchor (side by window) ([bb88c82](https://github.com/jinyeow/ado-pr.nvim/commit/bb88c826fbcf10bd45a81283854323cb60eeba6e))
- Post inline PR comment threads via az devops invoke ([316552f](https://github.com/jinyeow/ado-pr.nvim/commit/316552fd09c5535897c9cceb2c14525ffb56275e))
- Fetch, filter and resolve PR comment threads ([5ae4bd7](https://github.com/jinyeow/ado-pr.nvim/commit/5ae4bd7697047c8b49d66aa695add12898717d5b))
- Show PR comment threads as signs in the diff ([7200bcd](https://github.com/jinyeow/ado-pr.nvim/commit/7200bcd32afb62a07c96166bdc75dd0ca0ac2dd3))
- Thread follower pane (#21) ([1024545](https://github.com/jinyeow/ado-pr.nvim/commit/10245452b57ba13e25f456da2489eeaabf74df90))
- Anchor left-side threads in every diffview layout (#22) ([9e5728b](https://github.com/jinyeow/ado-pr.nvim/commit/9e5728b97a89e3b7df9ce069376c602a614abbc5))


### Miscellaneous
- Reformat with stylua, enforce lint gate (#41) ([d3dc12b](https://github.com/jinyeow/ado-pr.nvim/commit/d3dc12b2ae61b3b5cb3dd38193e67b5325b97893))


### Refactoring
- Extract diffview_state accessor for anchor.lua ([6b7a8f8](https://github.com/jinyeow/ado-pr.nvim/commit/6b7a8f8097ae8a0af722810079514869bcd1093f))
- Extract pure placement plan from M.refresh (#32) ([6dbf0ca](https://github.com/jinyeow/ado-pr.nvim/commit/6dbf0cabc3e57a9cc514987b068acea138e17b84))
- Extract resolved-thread collection into resolved_threads.lua (#45) ([8ae252a](https://github.com/jinyeow/ado-pr.nvim/commit/8ae252a1ad6d72694e819c8f1df60531da2e7761))


### Testing
- Cover diffview_state.current() accessor ([5d3adc4](https://github.com/jinyeow/ado-pr.nvim/commit/5d3adc40fe3b580c28bec61fb3ac754fa7c306a5))


