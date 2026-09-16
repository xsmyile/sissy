<!--
Keep it short: the title and the commits usually say it.
A sentence here is for the why a reviewer cannot infer from the diff.
-->

- [ ] `swift-format` and `swiftlint` pass (`pre-commit run --all-files`)
- [ ] `xcodegen generate` re-run, if Swift files were added or removed
- [ ] `sissy-cli --self-test` run against a fresh build, if the engine changed
